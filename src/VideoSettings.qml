import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Shared by the permanent inspector and its modal keyboard-accessible view.
// Edits go to the backend, so both views always reflect the same settings.
ColumnLayout {
    id: settings
    property bool compact: true
    signal doneRequested()
    spacing: compact ? 12 : 16

    function setEdge(edge, percent) {
        var c = backend.crop, n = percent / 100;
        var left = c.x, top = c.y, right = c.x + c.width, bottom = c.y + c.height;
        if (edge === 0) left = Math.min(n, right - 0.02);
        if (edge === 1) top = Math.min(n, bottom - 0.02);
        if (edge === 2) right = Math.max(n, left + 0.02);
        if (edge === 3) bottom = Math.max(n, top + 0.02);
        backend.crop = Qt.rect(left, top, right - left, bottom - top);
    }

    component SettingsButton: Button {
        id: button
        implicitHeight: Math.max(32, contentItem.implicitHeight + 12)
        implicitWidth: contentItem.implicitWidth + 20
        padding: 8
        topInset: 0; bottomInset: 0; leftInset: 0; rightInset: 0
        focusPolicy: Qt.TabFocus
        contentItem: Text {
            text: button.text
            font.pixelSize: 12
            font.weight: Font.Medium
            color: button.enabled ? (button.highlighted ? theme.accentForeground : "#dddfe8") : "#626570"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
        }
        background: Rectangle {
            color: button.highlighted ? theme.accent : button.down ? "#353842" : button.hovered ? "#30333c" : "#23252d"
            border.color: button.activeFocus ? theme.accent : "#393c47"
            radius: Math.min(4, theme.radius)
            opacity: button.enabled ? 1 : 0.6
        }
    }

    Label {
        text: qsTr("Video settings")
        font.pixelSize: settings.compact ? 14 : 20
        font.weight: Font.DemiBold
        color: "#f0f0f5"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    Label {
        visible: !settings.compact
        text: qsTr("Applies to the whole edit. Preview updates immediately.")
        color: "#9296a5"
        font.pixelSize: 12
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    RowLayout {
        Layout.fillWidth: true
        SettingsButton {
            text: qsTr("Rotate 90°")
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            onClicked: backend.rotation = (backend.rotation + 90) % 360
        }
        Label { text: backend.rotation + "°"; color: "#a7aab6"; font.pixelSize: 12 }
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#2b2e37" }
    Label {
        text: qsTr("Crop edges (% of the original image)")
        color: "#a7aab6"
        font.pixelSize: 11
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    GridLayout {
        columns: 2
        columnSpacing: 8
        rowSpacing: 8
        Layout.fillWidth: true
        Repeater {
            model: [
                {label: qsTr("Left"), edge: 0}, {label: qsTr("Right"), edge: 2},
                {label: qsTr("Top"), edge: 1}, {label: qsTr("Bottom"), edge: 3}
            ]
            delegate: ColumnLayout {
                id: cropControl
                required property var modelData
                spacing: 4
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Label { text: cropControl.modelData.label; color: "#8f93a2"; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
                SpinBox {
                    id: number
                    from: 0; to: 100; editable: true
                    implicitWidth: 84; implicitHeight: 30
                    Layout.fillWidth: true
                    Layout.minimumWidth: 76
                    leftPadding: 20; rightPadding: 20
                    topPadding: 3; bottomPadding: 3
                    value: Math.round(100 * (cropControl.modelData.edge === 0 ? backend.crop.x : cropControl.modelData.edge === 1 ? backend.crop.y : cropControl.modelData.edge === 2 ? backend.crop.x + backend.crop.width : backend.crop.y + backend.crop.height))
                    onValueModified: settings.setEdge(cropControl.modelData.edge, value)
                    contentItem: TextInput {
                        objectName: (settings.compact ? "inspectorCrop" : "dialogCrop") + modelData.edge
                        text: number.displayText
                        color: "#ececf4"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        readOnly: !number.editable
                        validator: number.validator
                        inputMethodHints: Qt.ImhDigitsOnly
                        selectByMouse: true
                        selectionColor: theme.accent
                        selectedTextColor: theme.accentForeground
                    }
                    background: Rectangle { color: "#15171c"; border.color: number.activeFocus ? theme.accent : "#343741"; radius: Math.min(4, theme.radius) }
                    down.indicator: Rectangle {
                        x: 1; y: 1; width: 19; height: number.height - 2
                        color: number.down.pressed ? "#353842" : "transparent"
                        Text { anchors.centerIn: parent; text: "−"; color: number.value > number.from ? "#b4b7c3" : "#515562"; font.pixelSize: 15 }
                    }
                    up.indicator: Rectangle {
                        x: number.width - width - 1; y: 1; width: 19; height: number.height - 2
                        color: number.up.pressed ? "#353842" : "transparent"
                        Text { anchors.centerIn: parent; text: "+"; color: number.value < number.to ? "#b4b7c3" : "#515562"; font.pixelSize: 15 }
                    }
                }
            }
        }
    }
    SettingsButton { text: qsTr("Reset crop"); Layout.fillWidth: true; Layout.minimumWidth: 0; onClicked: backend.crop = Qt.rect(0, 0, 1, 1) }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#2b2e37" }
    RowLayout {
        Layout.fillWidth: true
        Label { text: qsTr("Volume"); color: "#a7aab6"; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight }
        Label { text: Math.round(backend.volume * 100) + "%"; color: "#ececf4"; font.pixelSize: 12 }
    }
    Slider {
        id: volumeSlider
        Layout.fillWidth: true
        implicitHeight: 22
        from: 0; to: 1
        value: backend.volume
        onMoved: backend.volume = value
        background: Rectangle {
            x: volumeSlider.leftPadding; y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
            width: volumeSlider.availableWidth; height: 3
            color: "#393d48"
            Rectangle { width: volumeSlider.visualPosition * parent.width; height: parent.height; color: theme.accent }
        }
        handle: Rectangle {
            x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
            y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
            width: 10; height: 10; radius: 5; color: theme.accent
        }
    }
    SettingsButton { text: backend.volume === 0 ? qsTr("Unmute") : qsTr("Mute"); Layout.fillWidth: true; Layout.minimumWidth: 0; onClicked: backend.volume = backend.volume === 0 ? 1 : 0 }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#2b2e37" }
    CheckBox {
        id: fastMode
        Layout.fillWidth: true
        implicitHeight: Math.max(30, contentItem.implicitHeight + 8)
        padding: 0; spacing: 8
        text: qsTr("Fast save without re-encoding")
        enabled: backend.fastExportAvailable
        checked: backend.fastExport && enabled
        onToggled: backend.fastExport = checked
        contentItem: Text {
            text: fastMode.text
            leftPadding: 26
            color: fastMode.enabled ? "#daddE7" : "#717582"
            font.pixelSize: 11
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
        }
        indicator: Rectangle {
            x: 0; y: (fastMode.height - height) / 2; width: 16; height: 16
            radius: Math.min(3, theme.radius)
            color: fastMode.checked ? theme.accent : "#17191f"
            border.color: fastMode.activeFocus ? theme.accent : "#5c606d"
            Text { anchors.centerIn: parent; text: fastMode.checked ? "✓" : ""; color: theme.accentForeground; font.pixelSize: 11 }
        }
    }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font.pixelSize: 10
        lineHeight: 1.15
        text: backend.fastExportAvailable
            ? qsTr("Fast mode cuts at keyframes: the actual start and duration may shift. Leave it off for exact cuts.")
            : qsTr("Fast mode needs one continuous MP4 segment with no image or audio changes.")
        color: "#a69b75"
    }
    SettingsButton {
        text: qsTr("Reset settings")
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        onClicked: { backend.rotation = 0; backend.crop = Qt.rect(0, 0, 1, 1); backend.volume = 1; backend.fastExport = false }
    }
    SettingsButton { visible: !settings.compact; text: qsTr("Done"); highlighted: true; Layout.fillWidth: true; Layout.minimumWidth: 0; onClicked: settings.doneRequested() }
}
