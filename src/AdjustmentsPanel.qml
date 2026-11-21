import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

Popup {
    id: panel
    modal: true
    focus: true
    padding: 24
    Material.roundedScale: theme.radius
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    Overlay.modal: Rectangle { color: "#99000000" }
    background: Rectangle { color: "#1c1e25"; radius: theme.radius; border.color: "#363a46" }
    height: Math.min(settings.implicitHeight + 2 * padding, parent.height - 32)

    contentItem: ScrollView {
        clip: true
        contentWidth: panel.availableWidth
        contentHeight: settings.implicitHeight
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        VideoSettings {
            id: settings
            width: panel.availableWidth
            compact: false
            onDoneRequested: panel.close()
        }
    }
}
