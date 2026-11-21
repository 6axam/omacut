#include <QtTest>
#include <QCryptographicHash>
#include <QFile>
#include <QProcess>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <cmath>
#include <cstring>
#include <unistd.h>

#include "backend.h"
#include "filepicker.h"
#include "thumbprovider.h"

namespace {
class Picker : public FilePicker {
public:
    void openVideo() override {}
    void exportVideo(const QUrl &, const QList<int> &) override {}
};

QByteArray run(const QStringList &args, bool *ok = nullptr) {
    QProcess process;
    process.start(QStringLiteral("ffmpeg"), args);
    const bool success = process.waitForFinished(30000)
        && process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
    if (ok) *ok = success;
    if (!success) qWarning().noquote() << process.readAllStandardError();
    return process.readAllStandardOutput();
}

QByteArray sha256(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(&file);
    return hash.result();
}

QList<float> audio(const QString &path) {
    bool ok = false;
    const QByteArray bytes = run({"-v", "error", "-i", path, "-map", "0:a:0",
                                 "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1"}, &ok);
    if (!ok) return {};
    QList<float> values(bytes.size() / int(sizeof(float)));
    std::memcpy(values.data(), bytes.constData(), size_t(values.size()) * sizeof(float));
    return values;
}

struct Correlation { double value = -1; int lag = 0; };
Correlation alignment(const QList<float> &expected, const QList<float> &actual,
                      int from, int to) {
    Correlation best;
    const auto correlation = [&](int lag) {
        double xy = 0, xx = 0, yy = 0;
        for (int i = from; i < to; i += 8) {
            const int j = i + lag;
            if (j < 0 || j >= actual.size()) continue;
            const double x = expected[i], y = actual[j];
            xy += x * y; xx += x * x; yy += y * y;
        }
        return xy / std::sqrt(xx * yy);
    };
    for (int lag = -2400; lag <= 2400; lag += 16) {
        const double value = correlation(lag);
        if (value > best.value) best = {value, lag};
    }
    const int coarse = best.lag;
    for (int lag = coarse - 16; lag <= coarse + 16; ++lag) {
        const double value = correlation(lag);
        if (value > best.value) best = {value, lag};
    }
    return best;
}
}

class ScenarioTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase();
    void trimRemoveUndoExportPreservesFramesAndSound();
    void silentVideoExports();
    void adjustmentsSnapshotAndMute();
    void refusesSourceAndAliases();
    void fastExportIsExplicitAndLimited();
    void cancelAndErrorPreserveExistingOutput();
    void destructionCancelsExport();
    void cancelStopsWrittenPartial();
private:
    QTemporaryDir directory;
    QString source;
};

void ScenarioTests::initTestCase() {
    QVERIFY(directory.isValid());
    source = directory.filePath("frame-ids.mkv");
    bool ok = false;
    // The top row encodes the presentation-frame number as eight large binary
    // blocks. This survives lossy export and identifies every frame uniquely.
    // A chirp plus a fixed tone lets the waveform locate time independently.
    run({"-v", "error", "-y", "-f", "lavfi", "-i",
         "nullsrc=s=160x96:r=25:d=8,geq=lum='if(lt(Y,32),32+180*mod(floor(N/pow(2,floor(X/20))),2),20+N)':cb=128:cr=128",
         "-f", "lavfi", "-i",
         "aevalsrc=0.3*sin(2*PI*(220*t+17*t*t))+0.12*sin(2*PI*997*t):s=48000:d=8",
         "-c:v", "ffv1", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-shortest", source}, &ok);
    QVERIFY(ok);
    const auto info = ffmpeg::probe(source);
    QVERIFY(info.ok);
    QVERIFY(info.audio);
    QCOMPARE(info.duration, 8.0);
}

void ScenarioTests::trimRemoveUndoExportPreservesFramesAndSound() {
    const QByteArray original = sha256(source);
    ThumbProvider provider;
    Backend backend(&provider, new Picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(source)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    Timeline *timeline = backend.timeline();
    timeline->beginGesture();
    for (double in : {0.4, 0.8, 1.2, 1.6, 2.0}) timeline->moveEdge(0, true, in);
    timeline->endGesture();
    QCOMPARE(timeline->clips().first().in, 2.0);
    timeline->undo();
    QCOMPARE(timeline->clips().first().in, 0.0);
    QVERIFY(!timeline->canUndo());
    timeline->redo();
    QCOMPARE(timeline->clips().first().in, 2.0);
    timeline->split(2.0);
    timeline->split(4.0);
    QCOMPARE(timeline->clips().size(), 3);
    timeline->removeClip(1);
    QCOMPARE(timeline->duration(), 4.0);
    timeline->undo();
    QCOMPARE(timeline->clips().size(), 3);
    QCOMPARE(timeline->duration(), 6.0);
    timeline->redo();
    QCOMPARE(timeline->clips().size(), 2);
    QCOMPARE(timeline->clips()[0].in, 2.0);
    QCOMPARE(timeline->clips()[0].out, 4.0);
    QCOMPARE(timeline->clips()[1].in, 6.0);
    QCOMPARE(timeline->clips()[1].out, 8.0);

    const QString target = directory.filePath("edited.mp4");
    QSignalSpy done(&backend, &Backend::exportDone);
    QSignalSpy failed(&backend, &Backend::exportFailed);
    QSignalSpy progress(&backend, &Backend::exportProgressChanged);
    backend.exportClips(QUrl::fromLocalFile(target), timeline->clips());
    QTRY_VERIFY_WITH_TIMEOUT(done.count() + failed.count() > 0, 30000);
    QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed.first().first().toString()));
    QCOMPARE(done.size(), 1);
    QVERIFY(!progress.isEmpty());
    QCOMPARE(backend.exportProgress(), 1.0);
    QCOMPARE(sha256(source), original);
    QVERIFY(!timeline->unexported());
    const auto result = ffmpeg::probe(target);
    QVERIFY(result.ok);
    QVERIFY(result.audio);
    QVERIFY2(std::abs(result.duration - 4.0) < 0.04, qPrintable(QString::number(result.duration)));

    bool ok = false;
    const QByteArray pixels = run({"-v", "error", "-i", target, "-map", "0:v:0", "-pix_fmt", "gray",
                                  "-f", "rawvideo", "pipe:1"}, &ok);
    QVERIFY(ok);
    constexpr int frameBytes = 160 * 96;
    QCOMPARE(pixels.size(), 100 * frameBytes);
    for (int frame = 0; frame < 100; ++frame) {
        int identifier = 0;
        for (int bit = 0; bit < 8; ++bit) {
            const uchar sample = uchar(pixels.at(frame * frameBytes + 16 * 160 + bit * 20 + 10));
            if (sample > 128) identifier |= 1 << bit;
        }
        QCOMPARE(identifier, frame < 50 ? frame + 50 : frame + 100);
    }

    const QList<float> input = audio(source), output = audio(target);
    QVERIFY(input.size() >= 384000);
    QVERIFY(std::abs(output.size() - 192000) <= 1024);
    QList<float> expected = input.mid(96000, 96000);
    expected.append(input.mid(288000, 96000));
    const Correlation before = alignment(expected, output, 4800, 91200);
    const Correlation after = alignment(expected, output, 100800, 187200);
    qInfo() << "Audio before/after cut: correlation" << before.value << after.value
            << "lag in samples" << before.lag << after.lag;
    QVERIFY(before.value > 0.97);
    QVERIFY(after.value > 0.97);
    QVERIFY(std::abs(before.lag) < 1920);
    QVERIFY(std::abs(after.lag) < 1920);
    QVERIFY(std::abs(before.lag - after.lag) < 1920);
    QCOMPARE(sha256(source), original);
}

void ScenarioTests::silentVideoExports() {
    const QString silent = directory.filePath("silent.mkv");
    bool ok = false;
    run({"-v", "error", "-y", "-i", source, "-map", "0:v:0", "-c", "copy", silent}, &ok);
    QVERIFY(ok);
    ThumbProvider provider;
    Backend backend(&provider, new Picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(silent)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    backend.timeline()->setClip(0, 2, 4);
    const QString target = directory.filePath("silent-edited.mp4");
    QSignalSpy done(&backend, &Backend::exportDone);
    QSignalSpy failed(&backend, &Backend::exportFailed);
    backend.exportClips(QUrl::fromLocalFile(target), backend.timeline()->clips());
    QTRY_VERIFY_WITH_TIMEOUT(done.count() + failed.count() > 0, 30000);
    QCOMPARE(failed.size(), 0);
    QCOMPARE(done.size(), 1);
    const auto info = ffmpeg::probe(target);
    QVERIFY(info.ok);
    QVERIFY(!info.audio);
    QVERIFY(std::abs(info.duration - 2.0) < 0.04);
}

void ScenarioTests::adjustmentsSnapshotAndMute() {
    ThumbProvider provider;
    auto *picker = new Picker;
    Backend backend(&provider, picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(source)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    backend.timeline()->setClip(0, 2, 4);
    backend.setCrop(QRectF(0.25, 0, 0.5, 1));
    backend.setRotation(90);
    backend.setVolume(0.5);
    backend.exportDialog();
    // An asynchronous portal response must export the settings offered when
    // the dialog opened, even if the current edit changed while it was up.
    backend.setCrop(QRectF(0, 0, 1, 1));
    backend.setRotation(180);
    backend.setVolume(0);
    const QString target = directory.filePath("adjusted.mp4");
    QSignalSpy done(&backend, &Backend::exportDone), failed(&backend, &Backend::exportFailed);
    emit picker->exportSelected(QUrl::fromLocalFile(target), 0);
    QTRY_VERIFY_WITH_TIMEOUT(done.count() + failed.count() > 0, 30000);
    QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed.first().first().toString()));
    QCOMPARE(done.size(), 1);
    const auto info = ffmpeg::probe(target);
    QVERIFY(info.ok);
    QCOMPARE(info.width, 96);
    QCOMPARE(info.height, 80);
    QVERIFY(backend.adjustmentsDirty());
    const QList<float> input = audio(source).mid(96000, 96000), output = audio(target);
    QVERIFY(output.size() >= 96000);
    double xy = 0, xx = 0;
    for (int i = 4800; i < 91200; ++i) { xy += input[i] * output[i]; xx += input[i] * input[i]; }
    const double gain = xy / xx;
    QVERIFY2(std::abs(gain - 0.5) < 0.02, qPrintable(QString::number(gain)));

    const QString muted = directory.filePath("muted.mp4");
    backend.exportClips(QUrl::fromLocalFile(muted), backend.timeline()->clips());
    QTRY_VERIFY_WITH_TIMEOUT(done.count() + failed.count() > 1, 30000);
    QCOMPARE(failed.size(), 0);
    QCOMPARE(done.size(), 2);
    QVERIFY(!backend.adjustmentsDirty());
    const QList<float> silence = audio(muted);
    QVERIFY(!silence.isEmpty());
    for (float value : silence) QVERIFY(std::abs(value) < 0.000001);
    const auto mutedInfo = ffmpeg::probe(muted);
    QCOMPARE(mutedInfo.width, 160);
    QCOMPARE(mutedInfo.height, 96);
}

void ScenarioTests::refusesSourceAndAliases() {
    // Use MP4 so the exporter doesn't redirect the suffix before checking it.
    const QString video = directory.filePath("protected.mp4");
    bool ok = false;
    run({"-v", "error", "-y", "-i", source, "-c:v", "libx264", "-c:a", "aac", video}, &ok);
    QVERIFY(ok);
    const QByteArray original = sha256(video);
    const QString symlink = directory.filePath("symlink.mp4"), hardlink = directory.filePath("hardlink.mp4");
    QVERIFY(QFile::link(video, symlink));
    QCOMPARE(::link(QFile::encodeName(video).constData(), QFile::encodeName(hardlink).constData()), 0);
    ThumbProvider provider;
    Backend backend(&provider, new Picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(video)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    QSignalSpy failed(&backend, &Backend::exportFailed), done(&backend, &Backend::exportDone);
    for (const QString &target : {video, symlink, hardlink}) {
        const int count = failed.size();
        backend.exportClips(QUrl::fromLocalFile(target), {{0, 2, 4}});
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), count + 1, 10000);
        QVERIFY(!backend.busy());
        QCOMPARE(done.size(), 0);
        QCOMPARE(sha256(video), original);
    }
}

void ScenarioTests::fastExportIsExplicitAndLimited() {
    const QString video = directory.filePath("fast-source.mp4");
    bool ok = false;
    run({"-v", "error", "-y", "-i", source, "-t", "2", "-c:v", "libx264", "-c:a", "aac", video}, &ok);
    QVERIFY(ok);
    ThumbProvider provider;
    Backend backend(&provider, new Picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(video)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    QVERIFY(!backend.fastExport());
    QVERIFY(backend.fastExportAvailable());
    backend.setRotation(90);
    QVERIFY(!backend.fastExportAvailable());
    backend.setRotation(0);
    backend.setVolume(0.5);
    QVERIFY(!backend.fastExportAvailable());
    backend.setVolume(1);
    backend.setCrop(QRectF(0, 0, 0.5, 1));
    QVERIFY(!backend.fastExportAvailable());
    backend.setCrop(QRectF(0, 0, 1, 1));
    backend.timeline()->split(0.5);
    backend.timeline()->split(1.0);
    backend.timeline()->removeClip(1);
    QVERIFY(!backend.fastExportAvailable());
    backend.timeline()->undo();
    QVERIFY(backend.fastExportAvailable());
    backend.timeline()->setClip(0, 0.2, 0.5);
    backend.setFastExport(true);
    QVERIFY(backend.fastExport());
    const QString target = directory.filePath("fast-copy.mp4");
    QSignalSpy done(&backend, &Backend::exportDone), failed(&backend, &Backend::exportFailed);
    backend.exportClips(QUrl::fromLocalFile(target), backend.timeline()->clips());
    QTRY_VERIFY_WITH_TIMEOUT(done.count() + failed.count() > 0, 10000);
    QCOMPARE(failed.size(), 0);
    QCOMPARE(done.size(), 1);
    QVERIFY(ffmpeg::probe(target).ok);
    QVERIFY(ffmpeg::fastTrimArgs({video, 0.2, 2, true}, target).contains("copy"));
}

void ScenarioTests::cancelAndErrorPreserveExistingOutput() {
    ThumbProvider provider;
    Backend backend(&provider, new Picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(source)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    const QString target = directory.filePath("cancelled.mp4");
    QFile file(target);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("existing output must survive");
    file.close();
    const QByteArray original = sha256(target);
    QSignalSpy done(&backend, &Backend::exportDone), failed(&backend, &Backend::exportFailed);
    backend.exportClips(QUrl::fromLocalFile(target), backend.timeline()->clips());
    QVERIFY(backend.busy());
    backend.cancelExport();
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    QCOMPARE(done.size(), 0);
    QCOMPARE(sha256(target), original);
    QTRY_COMPARE(QDir(directory.path()).entryList({"*omacut*"}, QDir::Files | QDir::Hidden).size(), 0);
    const QString absent = directory.filePath("cancelled-new.mp4");
    backend.exportClips(QUrl::fromLocalFile(absent), backend.timeline()->clips());
    QVERIFY(backend.busy());
    backend.cancelExport();
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    QVERIFY(!QFileInfo::exists(absent));
    QTRY_COMPARE(QDir(directory.path()).entryList({"*omacut*"}, QDir::Files | QDir::Hidden).size(), 0);
    const QString missing = directory.filePath("absent/output.mp4");
    backend.exportClips(QUrl::fromLocalFile(missing), backend.timeline()->clips());
    QTRY_VERIFY_WITH_TIMEOUT(!failed.isEmpty(), 10000);
    QVERIFY(!backend.busy());
    QVERIFY(!QFileInfo::exists(missing));
    QCOMPARE(sha256(target), original);
}

void ScenarioTests::cancelStopsWrittenPartial() {
    ThumbProvider provider;
    Backend backend(&provider, new Picker);
    QVERIFY(backend.load(QUrl::fromLocalFile(source)));
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    QTemporaryDir tools;
    QVERIFY(tools.isValid());
    QFile executable(tools.filePath("ffmpeg"));
    QVERIFY(executable.open(QIODevice::WriteOnly));
    // A deterministic slow encoder writes a partial file and waits on stdin.
    // This tests killing a running process after output exists, rather than
    // merely cancelling before the encoder has had a chance to start.
    executable.write("#!/bin/sh\nfor target do :; done\nprintf partial > \"$target\"\nprintf 'out_time_us=1000000\\nprogress=continue\\n'\nread waiting\n");
    executable.close();
    QVERIFY(executable.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
    struct RestorePath {
        QByteArray original = qgetenv("PATH");
        ~RestorePath() { qputenv("PATH", original); }
    } restore;
    qputenv("PATH", QFile::encodeName(tools.path()) + ':' + restore.original);
    const QString target = directory.filePath("partial-cancel.mp4");
    QSignalSpy cancelled(&backend, &Backend::exportCancelled);
    backend.exportClips(QUrl::fromLocalFile(target), backend.timeline()->clips());
    QTRY_VERIFY_WITH_TIMEOUT(backend.exportProgress() > 0, 10000);
    QCOMPARE(backend.exportProgress(), 0.13);
    const auto partials = QDir(directory.path()).entryInfoList({"*omacut*"}, QDir::Files | QDir::Hidden);
    QCOMPARE(partials.size(), 1);
    QCOMPARE(partials.first().size(), 7);
    backend.cancelExport();
    QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
    QCOMPARE(cancelled.size(), 1);
    QVERIFY(!QFileInfo::exists(target));
    QVERIFY(!QFileInfo::exists(partials.first().absoluteFilePath()));

    QVERIFY(executable.open(QIODevice::WriteOnly | QIODevice::Truncate));
    executable.write("#!/bin/sh\nfor target do :; done\nprintf partial > \"$target\"\nexit 7\n");
    executable.close();
    const QString failedTarget = directory.filePath("partial-failed.mp4");
    QSignalSpy failed(&backend, &Backend::exportFailed);
    backend.exportClips(QUrl::fromLocalFile(failedTarget), backend.timeline()->clips());
    QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 10000);
    QVERIFY(!backend.busy());
    QVERIFY(!QFileInfo::exists(failedTarget));
    QCOMPARE(QDir(directory.path()).entryList({"*omacut*"}, QDir::Files | QDir::Hidden).size(), 0);
}

void ScenarioTests::destructionCancelsExport() {
    const QString target = directory.filePath("destroyed.mp4");
    ThumbProvider provider;
    {
        Backend backend(&provider, new Picker);
        QVERIFY(backend.load(QUrl::fromLocalFile(source)));
        QTRY_VERIFY_WITH_TIMEOUT(!backend.busy(), 10000);
        backend.exportClips(QUrl::fromLocalFile(target), backend.timeline()->clips());
        QVERIFY(backend.busy());
    }
    QVERIFY(!QFileInfo::exists(target));
    QTRY_COMPARE(QDir(directory.path()).entryList({"*omacut*"}, QDir::Files | QDir::Hidden).size(), 0);
}

QTEST_GUILESS_MAIN(ScenarioTests)
#include "scenario_tests.moc"
