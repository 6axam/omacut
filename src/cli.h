#pragma once

#include <QStringList>

namespace cli {
// Checked before constructing QGuiApplication, so headless commands need no display.
bool isCommand(const QString &argument);
int run(const QStringList &arguments);
}
