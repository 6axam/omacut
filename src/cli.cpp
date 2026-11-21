#include "cli.h"

#include <QCoreApplication>
#include <QEventLoop>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QTextStream>
#include <QTimer>

#include <cmath>
#include <csignal>

#include "backend.h"
#include "thumbprovider.h"

namespace {
volatile std::sig_atomic_t interrupted = 0;
void requestStop(int) { interrupted = 1; }

void printJson(const QJsonObject &object, FILE *stream) {
    QTextStream(stream) << QJsonDocument(object).toJson(QJsonDocument::Compact) << Qt::endl;
}

int fail(const QString &message, bool json) {
    if (json) printJson({{"ok", false}, {"error", message}}, stderr);
    else QTextStream(stderr) << message << Qt::endl;
    return 1;
}

bool finiteNumber(const QString &text, double *value) {
    bool ok = false;
    *value = text.toDouble(&ok);
    return ok && std::isfinite(*value);
}

void help() {
    QTextStream(stdout) <<
        "Usage:\n"
        "  omacut [VIDEO]\n"
        "  omacut check INPUT [--json]\n"
        "  omacut export INPUT OUTPUT [--clips START:END,...] [--rotate 0|90|180|270]\n"
        "         [--crop X,Y,WIDTH,HEIGHT] [--volume 0..1] [--fast] [--json]\n\n"
        "Times are source seconds; clip order is playback order. Crop coordinates are\n"
        "fractions of the unrotated video, applied before rotation. Defaults preserve\n"
        "the whole input. Output is MP4 and must differ from every original video.\n"
        "Precise export re-encodes by default. --fast copies one contiguous H.264/AAC\n"
        "MP4 segment: keyframes can shift the actual start and duration.\n"
        "SIGINT/SIGTERM stop export and remove its unfinished temporary file.\n" << Qt::endl;
}
}

namespace cli {
bool isCommand(const QString &argument) {
    return argument == "check" || argument == "export" || argument == "--help" || argument == "-h";
}

int run(const QStringList &arguments) {
    const bool json = arguments.contains("--json");
    const QString command = arguments.value(1);
    if (command == "--help" || command == "-h") {
        help();
        return 0;
    }

    QStringList positional;
    QString clipText;
    ffmpeg::Adjustments adjustments;
    bool fast = false;
    bool literal = false;
    QSet<QString> seen;
    for (int i = 2; i < arguments.size(); ++i) {
        const QString arg = arguments.at(i);
        if (!literal && arg == "--") { literal = true; continue; }
        if (literal || !arg.startsWith('-') || arg == "-") {
            positional << arg;
            continue;
        }
        if (seen.contains(arg)) return fail(QStringLiteral("Option specified twice: %1").arg(arg), json);
        seen.insert(arg);
        if (arg == "--help" || arg == "-h") { help(); return 0; }
        if (arg == "--json") continue;
        if (arg == "--fast" && command == "export") { fast = true; continue; }
        if (command != "export" || (arg != "--clips" && arg != "--rotate"
                && arg != "--volume" && arg != "--crop"))
            return fail(QStringLiteral("Unknown option: %1").arg(arg), json);
        if (++i >= arguments.size()) return fail(QStringLiteral("Missing value for %1").arg(arg), json);
        const QString value = arguments.at(i);
        if (arg == "--clips") {
            clipText = value;
        } else if (arg == "--rotate") {
            bool ok = false;
            const int rotation = value.toInt(&ok);
            if (!ok || (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270))
                return fail(QStringLiteral("Rotation must be 0, 90, 180 or 270."), json);
            adjustments.rotation = rotation;
        } else if (arg == "--volume") {
            if (!finiteNumber(value, &adjustments.volume) || adjustments.volume < 0 || adjustments.volume > 1)
                return fail(QStringLiteral("Volume must be between 0 and 1."), json);
        } else if (arg == "--crop") {
            const QStringList parts = value.split(',');
            double x = 0, y = 0, width = 0, height = 0;
            if (parts.size() != 4 || !finiteNumber(parts[0], &x) || !finiteNumber(parts[1], &y)
                    || !finiteNumber(parts[2], &width) || !finiteNumber(parts[3], &height)
                    || x < 0 || y < 0 || width < .01 || height < .01 || x + width > 1 || y + height > 1)
                return fail(QStringLiteral("Crop must be X,Y,WIDTH,HEIGHT inside 0..1, with sides at least 0.01."), json);
            adjustments.crop = QRectF(x, y, width, height);
        }
    }
    if (positional.size() != (command == "check" ? 1 : 2))
        return fail(QStringLiteral("Wrong number of paths. Run omacut --help."), json);
    const QString input = QFileInfo(positional.first()).absoluteFilePath();
    if (command == "check") {
        const auto info = ffmpeg::probe(input);
        if (!info.ok) return fail(info.error, json);
        if (json) {
            printJson({{"ok", true}, {"path", input}, {"duration", info.duration},
                       {"width", info.width}, {"height", info.height}, {"audio", info.audio},
                       {"fastCompatible", info.streamCopyCompatible}}, stdout);
        } else {
            QTextStream(stdout) << input << ": " << info.width << 'x' << info.height << ", "
                << info.duration << " s, audio=" << (info.audio ? "yes" : "no") << Qt::endl;
        }
        return 0;
    }

    edit::Clips requested;
    if (seen.contains("--clips")) {
        for (const QString &part : clipText.split(',')) {
            const QStringList range = part.split(':');
            double start = 0, end = 0;
            if (range.size() != 2 || !finiteNumber(range[0], &start) || !finiteNumber(range[1], &end)
                    || start < 0 || end <= start)
                return fail(QStringLiteral("Clips must be positive START:END ranges in source seconds."), json);
            requested.append({0, start, end});
        }
    }

    ThumbProvider provider;
    Backend backend(&provider);
    QEventLoop loop;
    int result = 1;
    auto failed = [&](const QString &message) {
        result = fail(message, json);
        loop.quit();
    };
    QObject::connect(&backend, &Backend::loadError, &loop, failed);
    QObject::connect(&backend, &Backend::exportFailed, &loop, failed);
    QObject::connect(&backend, &Backend::exportCancelled, &loop, [&] {
        failed(QStringLiteral("Export cancelled."));
    });
    QObject::connect(&backend, &Backend::exportDone, &loop, [&](const QString &path) {
        result = 0;
        if (json) printJson({{"ok", true}, {"path", path}, {"requestedDuration", edit::duration(requested)},
                            {"mode", fast ? "fast" : "precise"}}, stdout);
        else QTextStream(stdout) << path << Qt::endl;
        loop.quit();
    });
    QObject::connect(&backend, &Backend::infoChanged, &loop, [&] {
        // infoChanged arrives before the probe drops busy; start on the next turn.
        QTimer::singleShot(0, &loop, [&] {
            const double duration = backend.timeline()->duration();
            if (requested.isEmpty()) requested.append({0, 0, duration});
            for (const auto &clip : requested) {
                if (clip.out > duration + 0.0000001) {
                    failed(QStringLiteral("A clip extends past the input duration (%1 seconds).")
                               .arg(duration, 0, 'f', 6));
                    return;
                }
            }
            backend.timeline()->restore({duration}, requested);
            backend.setCrop(adjustments.crop);
            backend.setRotation(adjustments.rotation);
            backend.setVolume(adjustments.volume);
            if (fast && !backend.fastExportAvailable()) {
                failed(QStringLiteral("Fast saving requires one contiguous H.264/AAC MP4 segment without adjustments."));
                return;
            }
            backend.setFastExport(fast);
            if (fast) {
                const QString warning = QStringLiteral("Fast saving follows keyframes; the actual start and duration may shift.");
                if (json) printJson({{"warning", warning}}, stderr);
                else QTextStream(stderr) << warning << Qt::endl;
            }
            backend.exportClips(QUrl::fromLocalFile(QFileInfo(positional.at(1)).absoluteFilePath()), requested);
        });
    });
    interrupted = 0;
    const auto oldInt = std::signal(SIGINT, requestStop);
    const auto oldTerm = std::signal(SIGTERM, requestStop);
    QTimer interruptTimer;
    interruptTimer.setInterval(50);
    QObject::connect(&interruptTimer, &QTimer::timeout, &loop, [&] {
        if (!interrupted) return;
        if (backend.exporting()) backend.cancelExport();
        else failed(QStringLiteral("Export cancelled."));
    });
    interruptTimer.start();
    if (backend.load(QUrl::fromLocalFile(input))) loop.exec();
    std::signal(SIGINT, oldInt);
    std::signal(SIGTERM, oldTerm);
    return result;
}
}
