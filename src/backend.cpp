#include "backend.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QPointer>
#include <QProcess>
#include <QTemporaryFile>
#include <QThreadPool>
#include <QTimer>
#include <QVariantMap>

#include <cstdio>
#include <cmath>
#include <sys/stat.h>
#include <functional>
#include <memory>
#include <utility>

#include "filepicker.h"
#include "portalfilepicker.h"
#include "thumbprovider.h"

namespace {
QString mp4PathFor(const QString &path) {
    const QFileInfo file(path);
    if (file.suffix().compare(QStringLiteral("mp4"), Qt::CaseInsensitive) == 0)
        return path;

    const QString baseName = file.completeBaseName().isEmpty()
        ? file.fileName()
        : file.completeBaseName();
    return file.dir().filePath(baseName + QStringLiteral(".mp4"));
}

bool replaceWithTemp(const QString &tmpPath, const QString &outPath) {
    const QByteArray tmpName = QFile::encodeName(tmpPath);
    const QByteArray outName = QFile::encodeName(outPath);
    return std::rename(tmpName.constData(), outName.constData()) == 0;
}
}

Backend::Backend(ThumbProvider *provider, QObject *parent)
    : Backend(provider, new PortalFilePicker(), parent) {}

Backend::Backend(ThumbProvider *provider, FilePicker *filePicker, QObject *parent)
    : QObject(parent), m_provider(provider), m_filePicker(filePicker) {
    if (!m_filePicker->parent())
        m_filePicker->setParent(this);
    wireFilePicker();
    connect(&m_timeline, &Timeline::changed, this, [this] {
        if (!fastExportAvailable()) m_fastExport = false;
        emit adjustmentsChanged();
    });
}

Backend::~Backend() {
    // Stop writers before deleting their temporary files, including during quit.
    for (QProcess *process : findChildren<QProcess *>()) {
        process->disconnect(this);
        if (process->state() != QProcess::NotRunning) {
            process->kill();
            process->waitForFinished(3000);
        }
    }
    if (!m_exportPart.isEmpty())
        QFile::remove(m_exportPart);
    // Quit mid-save: the ffmpeg writing it dies with us, so its file goes too.
    if (!m_framePart.isEmpty())
        QFile::remove(m_framePart);
}

void Backend::wireFilePicker() {
    connect(m_filePicker, &FilePicker::openSelected, this, [this](const QUrl &url) {
        if (std::exchange(m_adding, false))
            addVideo(url, m_addAt);
        else
            load(url);
    });
    connect(m_filePicker, &FilePicker::exportSelected, this, [this](const QUrl &url, int scaleHeight) {
        exportClipsWithSettings(url, m_exportDialogClips, scaleHeight,
                                m_exportDialogAdjustments, m_exportDialogFast);
    });
    connect(m_filePicker, &FilePicker::failed, this, &Backend::loadError);
}

void Backend::setBusy(bool busy) {
    if (m_busy == busy)
        return;
    m_busy = busy;
    emit busyChanged();
}

void Backend::setStatus(const QString &status) {
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

bool Backend::isVideoPath(const QString &path) const {
    const QString target = QFileInfo(path).canonicalFilePath();
    struct stat targetStat {};
    const bool targetExists = ::stat(QFile::encodeName(path).constData(), &targetStat) == 0;
    for (const Video &video : m_videos) {
        const QString source = QFileInfo(video.info.path).canonicalFilePath();
        if ((!target.isEmpty() && source == target)
                || QDir::cleanPath(QFileInfo(path).absoluteFilePath())
                   == QDir::cleanPath(QFileInfo(video.info.path).absoluteFilePath()))
            return true;
        struct stat sourceStat {};
        if (targetExists && ::stat(QFile::encodeName(video.info.path).constData(), &sourceStat) == 0
                && sourceStat.st_dev == targetStat.st_dev && sourceStat.st_ino == targetStat.st_ino)
            return true;
    }
    return false;
}

void Backend::setExportProgress(double progress) {
    progress = qBound(0.0, progress, 1.0);
    if (m_exportProgress == progress) return;
    m_exportProgress = progress;
    emit exportProgressChanged();
}

void Backend::setRotation(int rotation) {
    rotation = ((rotation % 360) + 360) % 360;
    if (rotation % 90 || m_adjustments.rotation == rotation || busy()) return;
    m_adjustments.rotation = rotation;
    m_fastExport = false;
    emit adjustmentsChanged();
}

void Backend::setVolume(double volume) {
    if (!std::isfinite(volume) || busy()) return;
    volume = qBound(0.0, volume, 1.0);
    if (m_adjustments.volume == volume) return;
    m_adjustments.volume = volume;
    m_fastExport = false;
    emit adjustmentsChanged();
}

void Backend::setCrop(const QRectF &crop) {
    if (busy() || !std::isfinite(crop.x()) || !std::isfinite(crop.y())
            || !std::isfinite(crop.width()) || !std::isfinite(crop.height())
            || crop.x() < 0 || crop.y() < 0 || crop.width() < 0.01 || crop.height() < 0.01
            || crop.right() > 1.0000001 || crop.bottom() > 1.0000001 || m_adjustments.crop == crop)
        return;
    m_adjustments.crop = crop;
    m_fastExport = false;
    emit adjustmentsChanged();
}

void Backend::setFastExport(bool enabled) {
    enabled = enabled && fastExportAvailable();
    if (m_fastExport == enabled || busy()) return;
    m_fastExport = enabled;
    emit adjustmentsChanged();
}

bool Backend::fastExportAvailable() const {
    const auto clips = edit::merged(m_timeline.clips());
    return clips.size() == 1 && clips.first().source >= 0 && clips.first().source < m_videos.size()
        && m_videos[clips.first().source].info.streamCopyCompatible
        && m_adjustments == ffmpeg::Adjustments();
}

void Backend::cancelExport() {
    if (!m_exportProcess || !exporting()) return;
    m_exportCancelRequested = true;
    m_exportProcess->kill();
}

QVariantList Backend::videoList() const {
    QVariantList result;
    for (const Video &video : m_videos)
        result.append(QVariantMap{{QStringLiteral("url"), video.url},
                                  {QStringLiteral("thumbKey"), video.thumbKey}});
    return result;
}

bool Backend::checkedPath(const QUrl &url, QString *path) {
    // Only absolute local paths reach ffprobe: "file:-report" would be read
    // as an option, and "file:http://..." as a network address.
    *path = url.toLocalFile();
    if (!url.isLocalFile() || !QDir::isAbsolutePath(*path)) {
        emit loadError(tr("Only local files can be opened."));
        return false;
    }
    return true;
}

void Backend::enqueueVideo(const PendingVideo &pending) {
    m_probeQueue.append(pending);
    startNextProbe();
}

void Backend::startNextProbe() {
    if (m_probing || m_probeQueue.isEmpty())
        return;
    const PendingVideo pending = m_probeQueue.takeFirst();
    m_probing = true;
    emit busyChanged();

    // ffprobe can take seconds on a streamed file with no header duration,
    // so it runs on a worker thread; only applying the result needs the UI
    // thread. The guard is only read back on the UI thread, and drops the
    // result if this backend is already gone by then.
    const QPointer<Backend> guard(this);
    QThreadPool::globalInstance()->start([guard, pending] {
        const ffmpeg::VideoInfo info = ffmpeg::probe(pending.path);
        QMetaObject::invokeMethod(QCoreApplication::instance(), [guard, pending, info] {
            if (guard)
                guard->applyProbe(pending, info);
        }, Qt::QueuedConnection);
    });
}

void Backend::applyProbe(const PendingVideo &pending, const ffmpeg::VideoInfo &info) {
    if (!info.ok) {
        // An export that rewrote its own source reports done either way;
        // the reopen failing is the part the user needs explained.
        if (pending.exportReload) {
            emit exportDone(pending.path);
            emit exportReopenFailed();
        } else {
            emit loadError(info.error);
        }
        if (pending.batch)
            ++m_batchSkipped;
    } else {
        Video video;
        video.info = info;
        video.url = pending.url;
        video.thumbKey = ++m_nextThumbKey;
        m_provider->setVideo(video.thumbKey, video.info.path);
        if (pending.batch)
            ++m_batchAdded;

        if (!pending.adding || m_videos.isEmpty()) {
            m_videos = {video};
            m_adjustments = {};
            m_exportedAdjustments = {};
            m_fastExport = false;
            emit adjustmentsChanged();
            m_timeline.reset(video.info.duration);
            emit videosChanged();
            emit infoChanged();
        } else {
            // A chained batch add lands after the clip the previous batch
            // member landed on, so retarget the rest of the batch at it.
            const int inserted = m_timeline.clipAt(pending.addAt) + 1;
            m_videos.append(video);
            emit videosChanged();
            m_timeline.addSource(video.info.duration, pending.addAt);
            if (pending.chain) {
                const double start = m_timeline.clipStart(inserted);
                for (PendingVideo &queued : m_probeQueue) {
                    if (queued.batch == pending.batch)
                        queued.addAt = start;
                }
            }
        }
        // Only now, with the saved file reopened, is the export fully
        // done: reporting earlier let the reload erase the "Saved" notice
        // and reset the timeline under edits made in between.
        if (pending.exportReload)
            emit exportDone(pending.path);
    }

    m_probing = false;
    if (!m_probeQueue.isEmpty()) {
        startNextProbe();
        return;
    }
    emit busyChanged();
    if (m_batchAdded > 0 && m_batchSkipped > 0)
        emit skippedVideos(m_batchSkipped);
    m_batchAdded = 0;
    m_batchSkipped = 0;
}

bool Backend::load(const QUrl &url) {
    // A running export marks its clips exported when it finishes, which
    // must not land on a different set of videos.
    if (busy())
        return false;

    PendingVideo pending;
    pending.url = url;
    pending.adding = false;
    if (!checkedPath(url, &pending.path))
        return false;
    enqueueVideo(pending);
    return true;
}

bool Backend::addVideo(const QUrl &url, double t) {
    if (busy())
        return false;
    if (m_videos.isEmpty())
        return load(url);

    PendingVideo pending;
    pending.url = url;
    pending.adding = true;
    pending.addAt = t;
    if (!checkedPath(url, &pending.path))
        return false;
    enqueueVideo(pending);
    return true;
}

bool Backend::addVideos(const QVariantList &urls, double t) {
    if (busy() || urls.isEmpty())
        return false;

    const int batch = ++m_nextBatch;
    int queued = 0;
    for (const QVariant &value : urls) {
        PendingVideo pending;
        pending.url = value.toUrl();
        pending.adding = true;
        pending.chain = true;
        pending.addAt = t;
        pending.batch = batch;
        if (!checkedPath(pending.url, &pending.path)) {
            ++m_batchSkipped;
            continue;
        }
        m_probeQueue.append(pending);
        ++queued;
    }
    if (queued == 0) {
        // Nothing probed, so nothing loaded: the per-file errors already
        // said why, and the batch counters start clean for the next batch.
        m_batchAdded = 0;
        m_batchSkipped = 0;
        return false;
    }
    startNextProbe();
    return true;
}

void Backend::openVideoDialog() {
    m_adding = false;
    m_filePicker->openVideo();
}

void Backend::addVideoDialog(double t) {
    m_adding = !m_videos.isEmpty();
    m_addAt = t;
    m_filePicker->openVideo();
}

void Backend::exportDialog() {
    if (m_videos.isEmpty())
        return;

    m_exportDialogClips = m_timeline.clips();
    m_exportDialogAdjustments = m_adjustments;
    m_exportDialogFast = m_fastExport && fastExportAvailable();
    const ffmpeg::VideoInfo &frame = m_videos.value(m_exportDialogClips.value(0).source).info;
    m_filePicker->exportVideo(suggestedExportUrl(), m_exportDialogFast ? QList<int>()
                                               : exportHeights(frame.width, frame.height));
}

void Backend::stepFrame(double t, int direction) {
    if (m_steppingFrame || busy() || m_timeline.duration() <= 0 || !direction)
        return;
    t = qBound(0.0, t, m_timeline.duration());
    const edit::Clips clips = m_timeline.clips();
    int index = m_timeline.clipAt(t);
    // An edge belongs to the following clip, but stepping left from it
    // should show the previous clip's last frame. The player can round
    // that edge up by half a millisecond when reporting its position.
    constexpr double tolerance = 0.0005;
    if (direction < 0 && index > 0 && t - m_timeline.clipStart(index) <= tolerance)
        --index;
    const edit::Clip clip = clips.at(index);
    const double clipStart = m_timeline.clipStart(index);
    const bool atClipEnd = t >= m_timeline.clipStart(index + 1);
    const Video video = m_videos.at(clip.source);
    m_steppingFrame = true;
    const QPointer<Backend> guard(this);
    QThreadPool::globalInstance()->start([guard, video, clips, clip, clipStart, atClipEnd, t, direction] {
        const auto times = video.frameTimes.isEmpty()
            ? ffmpeg::frameTimes(video.info.path, video.info.start) : video.frameTimes;
        QMetaObject::invokeMethod(QCoreApplication::instance(),
            [guard, video, clips, clip, clipStart, atClipEnd, t, direction, times] {
                if (!guard)
                    return;
                guard->m_steppingFrame = false;
                if (guard->m_timeline.clips() != clips || guard->m_videos.value(clip.source).thumbKey != video.thumbKey)
                    return;
                if (times.isEmpty()) {
                    emit guard->frameStepFailed(tr("Could not read video frame times."));
                    return;
                }
                guard->m_videos[clip.source].frameTimes = times;
                const double sourceTime = atClipEnd ? clip.out : clip.in + t - clipStart;
                // Match the player's millisecond resolution, including rounded
                // timestamps at fractional frame rates.
                double target = direction < 0 ? clip.in : clip.out;
                if (direction > 0) {
                    for (double time : times) {
                        if (time > sourceTime + tolerance && time < clip.out) {
                            target = time;
                            break;
                        }
                    }
                } else {
                    // First find the frame currently on screen, then its predecessor.
                    double shown = clip.in;
                    for (double time : times) {
                        if (time > sourceTime + tolerance || time >= clip.out)
                            break;
                        if (time >= clip.in) {
                            target = shown;
                            shown = time;
                        }
                    }
                    // Only at/past the actual end: treating a frame just before
                    // it as the end would keep returning that same frame.
                    if (atClipEnd)
                        target = shown;
                }
                emit guard->frameStepped(t, clipStart + target - clip.in);
            }, Qt::QueuedConnection);
    });
}

void Backend::saveFrame(double t) {
    if (m_savingFrame || m_videos.isEmpty() || m_timeline.duration() <= 0)
        return;
    t = qBound(0.0, t, m_timeline.duration());
    const int index = m_timeline.clipAt(t);
    const edit::Clips clips = m_timeline.clips();
    if (index < 0 || index >= clips.size())
        return;
    const edit::Clip clip = clips.at(index);
    if (clip.source < 0 || clip.source >= m_videos.size())
        return;
    const double sourceTime = clip.in + (t - m_timeline.clipStart(index));
    const QString path = QFileInfo(m_videos.at(clip.source).info.path).absoluteFilePath();
    const double start = m_videos.at(clip.source).info.start;
    const QString ffprobeBin = ffmpeg::toolPath("ffprobe");
    const QString ffmpegBin = ffmpeg::toolPath("ffmpeg");
    if (ffprobeBin.isEmpty() || ffmpegBin.isEmpty()) {
        emit frameFailed(tr("ffmpeg is not installed."));
        return;
    }

    // In the background, as a 4K frame takes long enough to stall the
    // window: first find the frame on screen, then write it.
    m_savingFrame = true;
    runSaveFrameStep(ffprobeBin, ffmpeg::shownFrameArgs(path, start + sourceTime),
                 [this, path, start, sourceTime, ffmpegBin](const QByteArray &packetTimes) {
        const ffmpeg::ShownFrame shown = ffmpeg::shownFrame(packetTimes, start + sourceTime);
        const double frameTime = shown.time - start;
        const double keyframeTime = shown.keyframe >= 0.0 ? shown.keyframe - start : -1.0;
        const QFileInfo source(path);
        // Written under a hidden name, then given the first free one, so a
        // failed or interrupted save leaves no half PNG and never replaces one.
        QTemporaryFile part(source.absolutePath() + QStringLiteral("/.omacut-frame-XXXXXX.png"));
        part.setAutoRemove(false);
        if (!part.open()) {
            m_savingFrame = false;
            emit frameFailed(part.errorString());
            return;
        }
        const QString partPath = part.fileName();
        part.close();
        m_framePart = partPath;
        runSaveFrameStep(ffmpegBin, ffmpeg::frameArgs(path, frameTime, keyframeTime, partPath),
                     [this, source, partPath](const QByteArray &) {
            m_savingFrame = false;
            m_framePart.clear();
            if (QFileInfo(partPath).size() <= 0) {
                QFile::remove(partPath);
                emit frameFailed(tr("There's no frame there."));
                return;
            }
            const QString stem = source.absolutePath() + QLatin1Char('/') + source.completeBaseName();
            QString pngPath = stem + QStringLiteral("-frame.png");
            for (int n = 2; !QFile::rename(partPath, pngPath); ++n) {
                if (!QFileInfo::exists(pngPath) || n > 1000) {
                    QFile::remove(partPath);
                    emit frameFailed(tr("Could not write %1.").arg(pngPath));
                    return;
                }
                pngPath = stem + QStringLiteral("-frame-%1.png").arg(n);
            }
            // The temporary file was private; the frame is as shareable as any.
            QFile::setPermissions(pngPath, QFile::ReadOwner | QFile::WriteOwner
                                               | QFile::ReadGroup | QFile::ReadOther);
            emit frameSaved(pngPath);
        }, partPath);
    });
}

void Backend::runSaveFrameStep(const QString &program, const QStringList &args,
                           std::function<void(const QByteArray &)> done, const QString &partPath) {
    auto *proc = new QProcess(this);
    // A stuck file (say, on a hung network mount) mustn't block F for good.
    QTimer::singleShot(30000, proc, [proc] { proc->kill(); });
    connect(proc, &QProcess::finished, this,
            [this, proc, done, partPath](int code, QProcess::ExitStatus status) {
        const QByteArray out = proc->readAllStandardOutput();
        const QString err = QString::fromUtf8(proc->readAllStandardError()).trimmed();
        proc->deleteLater();
        if (status != QProcess::NormalExit || code != 0) {
            m_savingFrame = false;
            m_framePart.clear();
            if (!partPath.isEmpty())
                QFile::remove(partPath);
            emit frameFailed(err.isEmpty() ? tr("ffmpeg failed.") : err);
            return;
        }
        done(out);
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc, partPath](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart)
            return;
        m_savingFrame = false;
        m_framePart.clear();
        if (!partPath.isEmpty())
            QFile::remove(partPath);
        proc->deleteLater();
        emit frameFailed(proc->errorString());
    });
    proc->start(program, args);
}

QList<int> Backend::exportHeights(int width, int height) {
    const int shortSide = qMin(width, height);
    QList<int> heights;
    for (const int candidate : {1080, 720}) {
        if (shortSide > candidate)
            heights << candidate;
    }
    return heights;
}

QUrl Backend::suggestedExportUrl() const {
    if (m_videos.isEmpty())
        return {};
    const QFileInfo src(m_videos.first().info.path);
    const QString target = src.dir().filePath(src.completeBaseName() + "_trimmed.mp4");
    return QUrl::fromLocalFile(target);
}

void Backend::exportClips(const QUrl &dst, const edit::Clips &clips, int scaleHeight) {
    exportClipsWithSettings(dst, clips, scaleHeight, m_adjustments, m_fastExport);
}

void Backend::exportClipsWithSettings(const QUrl &dst, const edit::Clips &clips, int scaleHeight,
                                      const ffmpeg::Adjustments &adjustments, bool fast) {
    if (m_videos.isEmpty() || busy())
        return;

    QList<ffmpeg::Segment> segments;
    // The first clip that still has its video sets the frame.
    int frameSource = -1;
    for (const edit::Clip &clip : edit::merged(clips)) {
        if (clip.source < 0 || clip.source >= m_videos.size())
            continue;
        if (frameSource < 0)
            frameSource = clip.source;
        const ffmpeg::VideoInfo &info = m_videos[clip.source].info;
        segments.append({info.path, clip.in, clip.out, info.audio});
    }
    const double clipLen = edit::duration(clips);
    if (segments.isEmpty() || clipLen <= 0.0) {
        emit exportFailed(tr("The selected clip has no length."));
        return;
    }

    // Forcing the .mp4 suffix can redirect the write to a file the save
    // dialog never asked the user about overwriting — refuse rather than
    // silently replace it.
    const QString selectedPath = dst.toLocalFile();
    // Anything but an absolute local path would leave an empty or relative
    // one, which the .mp4 suffix turns into a file in the working directory,
    // or, with a host, "//host/..." that Linux reads as a local path.
    if (!dst.isLocalFile() || !dst.host().isEmpty() || !QDir::isAbsolutePath(selectedPath)) {
        emit exportFailed(QStringLiteral("Only local files can be exported to."));
        return;
    }
    const QString outPath = mp4PathFor(selectedPath);
    if (outPath != selectedPath && QFileInfo::exists(outPath)) {
        emit exportFailed(tr("%1 already exists.")
                              .arg(QFileInfo(outPath).fileName()));
        return;
    }

    if (isVideoPath(outPath)) {
        emit exportFailed(tr("The original video cannot be overwritten. Choose a different file."));
        return;
    }
    if (fast && (segments.size() != 1 || scaleHeight != 0
                 || adjustments != ffmpeg::Adjustments()
                 || !m_videos[frameSource].info.streamCopyCompatible)) {
        emit exportFailed(tr("Fast saving is unavailable for this edit. Use precise saving."));
        return;
    }

    const QString ffmpegBin = ffmpeg::toolPath("ffmpeg");
    if (ffmpegBin.isEmpty()) {
        emit exportFailed(tr("`ffmpeg` was not found on your PATH."));
        return;
    }

    setBusy(true);
    setExportProgress(0.0);
    m_exportCancelRequested = false;
    setStatus(tr("Exporting %1%").arg(0));

    // Encode to a sibling temp file and atomically replace the target only after
    // success, so failed/cancelled exports preserve any existing file.
    QTemporaryFile temporary(QFileInfo(outPath).dir().filePath(QStringLiteral(".omacut-XXXXXX.mp4")));
    temporary.setAutoRemove(false);
    if (!temporary.open()) {
        failExport(QString(), temporary.errorString());
        return;
    }
    const QString tmpPath = temporary.fileName();
    temporary.close();
    m_exportPart = tmpPath;
    const ffmpeg::VideoInfo &frame = m_videos[frameSource].info;
    const QStringList args = fast ? ffmpeg::fastTrimArgs(segments.first(), tmpPath)
        : ffmpeg::trimArgs(segments, tmpPath, frame.width, frame.height, scaleHeight, adjustments);

    auto *proc = new QProcess(this);
    m_exportProcess = proc;
    auto completed = std::make_shared<bool>(false);

    // ffmpeg -progress writes key=value blocks to stdout as it encodes;
    // out_time_us against the kept length gives the percentage.
    auto progressBuf = std::make_shared<QByteArray>();
    connect(proc, &QProcess::readyReadStandardOutput, this,
            [this, proc, progressBuf, clipLen, completed] {
                progressBuf->append(proc->readAllStandardOutput());
                int newline;
                while ((newline = progressBuf->indexOf('\n')) >= 0) {
                    const QByteArray line = progressBuf->left(newline).trimmed();
                    progressBuf->remove(0, newline + 1);
                    if (*completed || !line.startsWith("out_time_us="))
                        continue;
                    bool ok = false;
                    const double outSecs = line.mid(line.indexOf('=') + 1).toLongLong(&ok) / 1e6;
                    if (!ok)
                        continue;
                    const int percent = qBound(0, qRound(outSecs / clipLen * 100.0), 100);
                    setExportProgress(percent / 100.0);
                    setStatus(tr("Exporting %1%").arg(percent));
                }
            });

    connect(proc, &QProcess::finished, this,
            [this, proc, outPath, tmpPath, completed, clips, adjustments](int code, QProcess::ExitStatus exitStatus) {
                if (*completed)
                    return;
                *completed = true;
                const QString err = QString::fromUtf8(proc->readAllStandardError()).trimmed();
                proc->deleteLater();
                m_exportProcess = nullptr;
                if (m_exportCancelRequested) {
                    QFile::remove(tmpPath);
                    m_exportPart.clear();
                    setBusy(false);
                    setStatus(QString());
                    setExportProgress(0.0);
                    emit exportCancelled();
                    return;
                }
                if (exitStatus != QProcess::NormalExit || code != 0) {
                    failExport(tmpPath, err.isEmpty() ? tr("ffmpeg trim failed.") : err);
                    return;
                }
                // Check again immediately before publishing in case the target changed.
                if (isVideoPath(outPath)) {
                    failExport(tmpPath, tr("The original video cannot be overwritten. Choose a different file."));
                    return;
                }
                QFile::setPermissions(tmpPath, QFile::ReadOwner | QFile::WriteOwner
                                                | QFile::ReadGroup | QFile::ReadOther);
                if (!replaceWithTemp(tmpPath, outPath)) {
                    failExport(tmpPath, tr("Could not write the exported file."));
                    return;
                }
                m_exportPart.clear();
                setBusy(false);
                setExportProgress(1.0);
                setStatus(QString());
                m_timeline.markExported(clips);
                m_exportedAdjustments = adjustments;
                emit adjustmentsChanged();
                emit exportDone(outPath);
            });
    connect(proc, &QProcess::errorOccurred, this,
            [this, proc, tmpPath, completed](QProcess::ProcessError error) {
                if (error != QProcess::FailedToStart || *completed)
                    return;
                *completed = true;
                const QString err = proc->errorString();
                proc->deleteLater();
                failExport(tmpPath, err.isEmpty() ? tr("Could not start ffmpeg.") : err);
            });
    proc->start(ffmpegBin, args);
}

void Backend::failExport(const QString &tmpPath, const QString &message) {
    m_exportProcess = nullptr;
    m_exportPart.clear();
    setBusy(false);
    setStatus(QString());
    setExportProgress(0.0);
    if (!tmpPath.isEmpty()) QFile::remove(tmpPath);
    emit exportFailed(message);
}
