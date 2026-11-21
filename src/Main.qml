import QtQuick
import QtQml
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtMultimedia
import "Format.js" as Format

ApplicationWindow {
    id: win
    width: 1280
    height: 820
    minimumWidth: 760
    minimumHeight: 580
    visible: true
    title: backend.source.toString() === "" ? "omacut" : "omacut — " + fileName(backend.source)
    readonly property bool hasVideo: backend.source.toString() !== ""
    readonly property color accent: theme.accent
    readonly property color accentForeground: theme.accentForeground
    readonly property bool audioOutputReady: audioOutput !== null
    property var audioOutput: null
    property string noticeText: ""
    property bool helpVisible: false
    property bool quitConfirmVisible: false
    property bool openConfirmVisible: false
    readonly property string statusText: noticeText !== "" ? noticeText : backend.status
    // Right-to-left languages mirror the window; the Translator sets the
    // application's layout direction.
    readonly property bool rightToLeft: Qt.application.layoutDirection === Qt.RightToLeft

    readonly property var timeline: backend.timeline
    // Quitting only warns about unexported edits. One clip spanning the whole
    // first video is never dirty — that's just the source.
    readonly property bool unexported: hasVideo && (timeline.unexported || backend.adjustmentsDirty)
    // Quitting mid-export would stop it, so that asks too, edited or not.
    readonly property bool quitAsks: unexported || backend.exporting
    onQuitAsksChanged: if (!quitAsks) quitConfirmVisible = false
    // Editing shortcuts go quiet while a dialog or the help overlay is up,
    // a probe is about to replace the timeline, or a handle is dragged.
    // A confirmation or the shortcuts overlay is up, and has the keyboard.
    readonly property bool overlayOpen: quitConfirmVisible || openConfirmVisible || helpVisible || adjustmentsPanel.opened
    readonly property bool inputFocused: activeFocusItem !== null && activeFocusItem instanceof TextInput
    readonly property bool shortcutsEnabled: editing && !inputFocused
    readonly property bool editing: hasVideo && timeline.duration > 0 && !overlayOpen && !backend.busy && !editBar.interacting

    Material.theme: Material.Dark
    Material.accent: win.accent
    Material.roundedScale: theme.radius
    color: "#0d0e10"

    function fileName(url) {
        var s = url.toString();
        return s === "" ? "" : decodeURIComponent(s.substring(s.lastIndexOf('/') + 1));
    }
    function showNotice(text) {
        noticeText = text;
        noticeTimer.restart();
    }
    // Not while exporting: the export would mark the new edit as exported.
    // Replacing an unexported edit asks first, like quitting does.
    function openVideo() {
        if (backend.busy)
            return;
        if (unexported) {
            player.pause();
            openConfirmVisible = true;
            return;
        }
        backend.openVideoDialog();
    }
    function addVideo() {
        if (backend.busy)
            return;
        player.pause();
        backend.addVideoDialog(editBar.playheadSec);
    }
    // Dropped videos open into an empty window, and otherwise join the edit
    // after the clip under the playhead, in the order dropped, the way the +
    // button adds one. Adding is undoable, so a stray drop costs nothing.
    // Probing happens in the background, in drop order; a file that won't
    // open is skipped and the rest go on. When some made it, one notice
    // counts the skipped, since each error replaces the last.
    function dropVideos(urls) {
        return backend.addVideos(urls, editBar.playheadSec);
    }
    function exportVideo() {
        if (!win.hasVideo || timeline.duration <= 0 || backend.busy)
            return;
        player.pause();
        backend.exportDialog();
    }
    function ensureAudioOutput() {
        if (audioOutput === null && win.hasVideo)
            audioOutput = audioOutputComponent.createObject(win);
    }
    function releaseAudioOutput() {
        if (audioOutput === null)
            return;
        var oldAudioOutput = audioOutput;
        audioOutput = null;
        oldAudioOutput.destroy();
    }
    function playing() {
        return player.playbackState === MediaPlayer.PlayingState && !player.priming;
    }
    function togglePlay() {
        if (!win.hasVideo || timeline.duration <= 0)
            return;
        ensureAudioOutput();
        if (playing()) {
            player.pause();
            return;
        }
        // From the playhead, or from the top once at the end.
        var t = editBar.playheadSec >= timeline.duration - 0.03 ? 0 : editBar.playheadSec;
        var i = timeline.clipAt(t), clip = timeline.clips[i];
        editBar.playheadSec = t;
        player.show(i, clip.in + t - clip.start, true);
    }
    function seekTo(seconds) {
        if (!win.hasVideo || timeline.duration <= 0)
            return;
        var t = Math.max(0, Math.min(seconds, timeline.duration));
        var i = timeline.clipAt(t), clip = timeline.clips[i];
        editBar.playheadSec = t;
        player.show(i, clip.in + t - clip.start, playing());
    }
    // Moves the clip under the playhead one place earlier or later, keeping
    // the playhead on the same frame of it.
    function moveClipBy(direction) {
        var t = editBar.playheadSec, i = timeline.clipAt(t);
        var into = t - timeline.clipStart(i);
        if (i + direction < 0 || i + direction >= timeline.clips.length)
            return;
        timeline.moveClip(i, i + direction);
        seekTo(timeline.clipStart(i + direction) + into);
    }
    property bool quitting: false
    function requestQuit() {
        if (quitAsks) {
            if (player.playbackState === MediaPlayer.PlayingState)
                player.pause();
            quitConfirmVisible = true;
            return;
        }
        forceQuit();
    }
    // Closing the window is what reliably ends the app (quitOnLastWindowClosed);
    // Qt.quit() alone has proven ignorable in a live session, so it's only the
    // backstop. The quitting flag stops onClosing from re-asking on the way out.
    function forceQuit() {
        quitting = true;
        player.stop();
        releaseAudioOutput();
        win.close();
        Qt.quit();
    }

    Component.onCompleted: ensureAudioOutput()
    onHasVideoChanged: {
        if (hasVideo) {
            ensureAudioOutput();
        } else {
            player.stop();
            releaseAudioOutput();
        }
    }
    onClosing: (close) => {
        if (win.quitting)
            return;
        // A close with the open confirmation up just puts it away, rather
        // than stacking the quit confirmation on top of it.
        if (win.openConfirmVisible) {
            close.accepted = false;
            win.openConfirmVisible = false;
            return;
        }
        if (win.quitAsks) {
            close.accepted = false;
            requestQuit();
            return;
        }
        forceQuit();
    }

    // The playback and editing shortcuts go quiet while the quit confirmation is
    // up — a disabled Shortcut also stops swallowing its key, which lets the
    // dialog's own keyboard navigation receive the arrows, Space and Enter.
    // 0-9 jump to 0%-90% of the whole edit.
    Instantiator {
        model: 10
        delegate: Shortcut {
            required property int index
            sequence: index.toString()
            context: Qt.ApplicationShortcut
            enabled: win.shortcutsEnabled
            // Held down, repeats would keep seeking to the same spot.
            autoRepeat: false
            onActivated: seekTo(timeline.duration * index / 10)
        }
    }

    Shortcut {
        sequence: "Space"
        context: Qt.ApplicationShortcut
        enabled: win.hasVideo && !win.overlayOpen && !win.inputFocused
        onActivated: togglePlay()
    }

    Shortcut {
        sequence: "Left"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: win.playing() ? seekTo(editBar.playheadSec - 1) : frameStep(-1)
    }

    Shortcut {
        sequence: "Right"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: win.playing() ? seekTo(editBar.playheadSec + 1) : frameStep(1)
    }

    Shortcut {
        sequence: "Shift+Left"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: seekTo(editBar.playheadSec - 5)
    }

    Shortcut {
        sequence: "Shift+Right"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: seekTo(editBar.playheadSec + 5)
    }

    // A tap of Alt+Left/Right pauses and steps one video frame. Holding the
    // key repeats far faster than anyone taps, so a repeat within 100ms in
    // the same direction moves 0.2s instead, to cover ground quickly.
    function frameStep(direction) {
        player.pause();
        player.pendingPlay = false;
        backend.stepFrame(editBar.playheadSec, direction);
    }
    property double lastAltStepAt: 0
    property int lastAltStepDirection: 0
    function altStep(direction) {
        var now = Date.now();
        var held = direction === lastAltStepDirection && now - lastAltStepAt < 100;
        lastAltStepAt = now;
        lastAltStepDirection = direction;
        if (held) {
            seekTo(editBar.playheadSec + 0.2 * direction);
        } else {
            // A source still loading must not start playing once it's in.
            player.pause();
            player.pendingPlay = false;
            backend.stepFrame(editBar.playheadSec, direction);
        }
    }

    Shortcut {
        sequence: "Alt+Left"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: altStep(-1)
    }

    Shortcut {
        sequence: "Alt+Right"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: altStep(1)
    }

    Shortcut {
        sequence: "["
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: {
            player.pause();
            seekTo(timeline.edgeFrom(editBar.playheadSec, -1));
        }
    }

    Shortcut {
        sequence: "]"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: {
            player.pause();
            seekTo(timeline.edgeFrom(editBar.playheadSec, 1));
        }
    }

    Shortcut {
        sequence: "Alt+["
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: moveClipBy(-1)
    }

    Shortcut {
        sequence: "Alt+]"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled
        onActivated: moveClipBy(1)
    }

    Shortcut {
        sequence: "S"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: win.shortcutsEnabled
        onActivated: timeline.split(editBar.playheadSec)
    }

    Shortcut {
        sequences: ["X", "Delete", "Backspace"]
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: win.shortcutsEnabled
        onActivated: timeline.removeAt(editBar.playheadSec)
    }

    Shortcut {
        sequence: "Ctrl+Space"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: win.shortcutsEnabled
        onActivated: {
            // The frame under the playhead becomes the clip's first, and the
            // playhead stays on it: now the clip's start, not as far into the
            // edit as before, which would be further into the footage.
            var i = timeline.clipAt(editBar.playheadSec), was = timeline.clips[i].in;
            timeline.trimTo(editBar.playheadSec, true);
            // The edit's resync shows the frame, keeping a pending play.
            if (timeline.clips[i].in !== was)
                editBar.playheadSec = timeline.clipStart(i);
        }
    }

    Shortcut {
        sequence: "Ctrl+Shift+Space"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: win.shortcutsEnabled
        onActivated: {
            // The clip now ends at the playhead, and the playhead stays at the
            // cut, on the clip's last frame, as when dragging its end handle;
            // the frame at the playhead itself now belongs to what follows.
            var t = editBar.playheadSec, i = timeline.clipAt(t), was = timeline.clips[i].out;
            // Within a millisecond of the end, the playhead is on the last
            // frame already: the cut is here, so pressing again does nothing.
            if (timeline.clipStart(i) + was - timeline.clips[i].in - t < 0.002)
                return;
            timeline.trimTo(t, false);
            var clip = timeline.clips[i];
            if (clip.out !== was)
                editBar.playheadSec = timeline.clipStart(i) + clip.out - clip.in - 0.001;
        }
    }

    Shortcut {
        sequence: "Z"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: win.shortcutsEnabled
        onActivated: editBar.toggleZoom()
    }

    Shortcut {
        sequence: "F"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: win.shortcutsEnabled && !backend.busy
        onActivated: backend.saveFrame(editBar.playheadSec)
    }

    Shortcut {
        sequence: "Ctrl+Z"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled && timeline.canUndo
        onActivated: timeline.undo()
    }

    Shortcut {
        sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled && timeline.canRedo
        onActivated: timeline.redo()
    }

    Shortcut {
        sequence: "Ctrl+S"
        context: Qt.ApplicationShortcut
        enabled: win.hasVideo && timeline.duration > 0 && !backend.busy && !win.helpVisible && !win.openConfirmVisible
        onActivated: {
            win.quitConfirmVisible = false;
            exportVideo();
        }
    }

    Shortcut {
        sequence: "Ctrl+O"
        context: Qt.ApplicationShortcut
        enabled: !win.overlayOpen && !backend.busy
        onActivated: openVideo()
    }

    Shortcut {
        sequence: "Ctrl+Shift+O"
        context: Qt.ApplicationShortcut
        enabled: win.shortcutsEnabled && !backend.busy
        onActivated: addVideo()
    }

    // Off while a dialog is up, so the quit confirmation's own Q can answer:
    // two enabled shortcuts on one key are ambiguous and neither fires.
    Shortcut {
        sequence: "Q"
        context: Qt.ApplicationShortcut
        enabled: !win.overlayOpen && !win.inputFocused
        onActivated: requestQuit()
    }

    Shortcut {
        sequence: "?"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (!win.quitConfirmVisible && !win.openConfirmVisible)
                win.helpVisible = !win.helpVisible;
        }
    }

    Shortcut {
        sequence: "Escape"
        context: Qt.ApplicationShortcut
        onActivated: {
            if (win.quitConfirmVisible)
                win.quitConfirmVisible = false;
            else if (win.openConfirmVisible)
                win.openConfirmVisible = false;
            else if (win.helpVisible)
                win.helpVisible = false;
            else if (adjustmentsPanel.visible)
                adjustmentsPanel.close();
        }
    }

    MediaPlayer {
        id: player
        videoOutput: videoOut
        audioOutput: win.audioOutput

        // The clip on screen, and where to go once a newly set source has
        // loaded (pendingMs is -1 when nothing is waiting).
        property int clip: -1
        property int pendingMs: -1
        property bool pendingPlay: false
        // Switching sources first reports the old video as loaded again; only
        // a load that follows the new one starting counts.
        property bool loadStarted: false
        // A freshly loaded source shows black until played; playing it muted
        // until the first frame arrives, then pausing, puts that frame up.
        property bool priming: false
        property bool frameReady: false
        property int primeMs: 0
        // Keep the exact paused seek target: rounding a frame up to the
        // clip's end must not turn the next backward step into a repeat.
        property real pausedSourceTime: -1
        property int pausedSeekMs: -1

        function seekPosition(index, sourceTime, andPlay) {
            if (andPlay) return Math.round(sourceTime * 1000);
            // Qt presents the preceding frame at an exact timestamp boundary.
            // Seek just inside the requested frame, without crossing the out-point.
            var out = timeline.clips[index].out;
            return Math.max(0, Math.min(Math.floor(sourceTime * 1000) + 1, Math.ceil(out * 1000) - 1));
        }

        // Shows sourceTime in clip index, and plays on from there if asked.
        function show(index, sourceTime, andPlay) {
            var url = backend.videos[timeline.clips[index].source].url;
            var ms = seekPosition(index, sourceTime, andPlay);
            pausedSourceTime = andPlay ? -1 : sourceTime;
            pausedSeekMs = andPlay ? -1 : ms;
            clip = index;
            // Compared as text: url values are never identical as objects.
            if (source.toString() !== url.toString() || mediaStatus === MediaPlayer.LoadingMedia) {
                pendingMs = ms;
                pendingPlay = andPlay;
                loadStarted = mediaStatus === MediaPlayer.LoadingMedia && source.toString() === url.toString();
                frameReady = false;
                source = url;
                return;
            }
            pendingMs = -1;
            finishPriming();
            position = ms;
            if (andPlay)
                play();
            else
                startPriming(ms);
        }

        // Moves a load still in progress to sourceTime in clip index, keeping
        // whether it plays once loaded.
        function retarget(index, sourceTime) {
            var url = backend.videos[timeline.clips[index].source].url;
            if (source.toString() !== url.toString()) {
                show(index, sourceTime, pendingPlay);
                return;
            }
            clip = index;
            pausedSourceTime = pendingPlay ? -1 : sourceTime;
            pendingMs = seekPosition(index, sourceTime, pendingPlay);
            pausedSeekMs = pendingPlay ? -1 : pendingMs;
        }

        function startPriming(ms) {
            win.ensureAudioOutput();
            priming = true;
            primeMs = ms;
            position = ms;
            play();
            primeFallback.restart();
        }

        function finishPriming() {
            if (!priming)
                return;
            primeFallback.stop();
            pause();
            position = primeMs;
            priming = false;
        }

        onMediaStatusChanged: {
            // A video that won't load leaves nothing to wait for.
            if (mediaStatus === MediaPlayer.InvalidMedia)
                pendingMs = -1;
            if (mediaStatus === MediaPlayer.LoadingMedia)
                loadStarted = true;
            // Seeking or playing from inside this handler makes the player
            // load the video over again, so it waits for the handler to return.
            if (pendingMs >= 0 && loadStarted
                    && (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia))
                Qt.callLater(takePending);
        }
        function takePending() {
            if (pendingMs < 0)
                return;
            var ms = pendingMs;
            pendingMs = -1;
            if (pendingPlay) {
                position = ms;
                play();
            } else {
                startPriming(ms);
            }
        }
        onPositionChanged: {
            if (priming)
                return;
            if (pendingMs >= 0 || clip < 0 || clip >= timeline.clips.length)
                return;
            var c = timeline.clips[clip], t = player.position / 1000;
            if (!win.playing() && pausedSourceTime >= 0
                    && (player.position === pausedSeekMs || player.position === Math.round(pausedSourceTime * 1000)))
                t = pausedSourceTime;
            // Play the clips in order: carry on into a clip that continues
            // this one, jump to any other, and stop after the last.
            if (playbackState === MediaPlayer.PlayingState && t >= c.out - 0.03) {
                if (clip + 1 >= timeline.clips.length) {
                    pause();
                    editBar.playheadSec = timeline.duration;
                    return;
                }
                var next = timeline.clips[clip + 1];
                // A split's float noise still plays straight through. A real cut
                // has to seek, or the frames between out and the next in stay
                // on screen.
                if (!timeline.continues(clip)) {
                    show(clip + 1, next.in, true);
                    return;
                }
                clip += 1;
                c = next;
            }
            if (!editBar.interacting) {
                editBar.playheadSec = c.start + Math.max(0, Math.min(t, c.out) - c.in);
                if (win.playing()) editBar.revealPlayhead();
            }
        }
    }

    // After an edit, the clip under the playhead may be another one now, or
    // gone, so put the playhead's frame back up.
    Connections {
        target: win.timeline
        function onChanged() {
            Qt.callLater(win.resync);
        }
    }
    function resync() {
        if (!hasVideo || timeline.duration <= 0 || editBar.interacting)
            return;
        var t = Math.min(editBar.playheadSec, timeline.duration);
        var i = timeline.clipAt(t), clip = timeline.clips[i];
        var sourceTime = clip.in + t - clip.start;
        // Edited while a video loads: aim the wait at the playhead's clip now,
        // not the one it was started for.
        if (player.pendingMs >= 0) {
            player.retarget(i, sourceTime);
            return;
        }
        // Still playing the right stretch, e.g. after a split: no need to seek.
        if (playing() && backend.videos[clip.source].url.toString() === player.source.toString()
                && Math.abs(sourceTime - player.position / 1000) < 0.1) {
            player.clip = i;
            return;
        }
        editBar.playheadSec = t;
        player.show(i, sourceTime, playing());
    }

    Component {
        id: audioOutputComponent
        AudioOutput {
            // Follows the system's default output as it changes, between
            // headphones, speakers, monitor audio, etc. Created with the
            // output, so nothing watches devices before a video is open.
            property MediaDevices devices: MediaDevices {}
            device: devices.defaultAudioOutput
            muted: player.priming || backend.volume === 0
            volume: Math.min(1, backend.volume)
        }
    }

    Timer {
        id: primeFallback
        interval: 5000
        repeat: false
        onTriggered: player.finishPriming()
    }

    Timer {
        id: noticeTimer
        interval: 5000
        repeat: false
        onTriggered: win.noticeText = ""
    }

    component EditorButton: Button {
        id: control
        implicitHeight: 32
        implicitWidth: Math.max(32, label.implicitWidth + 24)
        leftPadding: 12; rightPadding: 12; topPadding: 6; bottomPadding: 6
        topInset: 0; bottomInset: 0; leftInset: 0; rightInset: 0
        focusPolicy: Qt.NoFocus
        opacity: enabled ? 1 : 0.35
        background: Rectangle {
            radius: Math.min(4, theme.radius)
            color: control.highlighted ? win.accent : control.hovered ? "#36383e" : "#27292e"
            border.color: control.highlighted ? win.accent : "#3a3c42"
        }
        contentItem: Text {
            id: label
            text: control.text
            font.pixelSize: 12; font.weight: control.highlighted ? Font.DemiBold : Font.Medium
            color: control.highlighted ? win.accentForeground : "#e1e2e5"
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    component IconButton: Rectangle {
        id: iconButton
        implicitWidth: 44
        implicitHeight: 44
        radius: 22

        property string iconName: "play"
        property color iconColor: "white"
        property color buttonColor: "#2c2c2f"
        property string tipText: ""
        signal clicked()

        color: buttonColor
        opacity: enabled ? 1 : 0.45

        HoverHandler { id: iconHover }
        ToolTip.visible: iconHover.hovered && tipText !== ""
        ToolTip.text: tipText

        Canvas {
            id: iconCanvas
            anchors.centerIn: parent
            width: 24
            height: 24

            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                ctx.fillStyle = iconButton.iconColor;
                ctx.strokeStyle = iconButton.iconColor;
                ctx.lineWidth = 2.4;
                ctx.lineCap = "round";
                ctx.lineJoin = "round";

                if (iconButton.iconName === "pause") {
                    ctx.fillRect(7, 5, 4, 14);
                    ctx.fillRect(14, 5, 4, 14);
                } else if (iconButton.iconName === "play") {
                    ctx.beginPath();
                    ctx.moveTo(8, 5);
                    ctx.lineTo(8, 19);
                    ctx.lineTo(19, 12);
                    ctx.closePath();
                    ctx.fill();
                } else if (iconButton.iconName === "plus") {
                    ctx.beginPath();
                    ctx.moveTo(12, 5);
                    ctx.lineTo(12, 19);
                    ctx.moveTo(5, 12);
                    ctx.lineTo(19, 12);
                    ctx.stroke();
                } else if (iconButton.iconName === "download") {
                    ctx.beginPath();
                    ctx.moveTo(12, 4);
                    ctx.lineTo(12, 14);
                    ctx.stroke();

                    ctx.beginPath();
                    ctx.moveTo(7, 10);
                    ctx.lineTo(12, 15);
                    ctx.lineTo(17, 10);
                    ctx.stroke();

                    ctx.beginPath();
                    ctx.moveTo(6, 20);
                    ctx.lineTo(18, 20);
                    ctx.stroke();
                }
            }

            Connections {
                target: iconButton
                function onIconNameChanged() { iconCanvas.requestPaint(); }
                function onIconColorChanged() { iconCanvas.requestPaint(); }
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: iconButton.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: iconButton.clicked()
        }
    }

    ColumnLayout {
        LayoutMirroring.enabled: win.rightToLeft
        LayoutMirroring.childrenInherit: true
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 48
            color: "#17181c"; radius: Math.min(6, theme.radius)
            RowLayout {
                anchors.fill: parent; anchors.margins: 10; spacing: 12
                Rectangle { width: 24; height: 24; radius: Math.min(4, theme.radius); color: win.accent
                    Text { anchors.centerIn: parent; text: "o"; color: win.accentForeground; font.bold: true; font.pixelSize: 20 }
                }
                Label { text: "omacut"; color: "#f3f4f6"; font.pixelSize: 16; font.bold: true }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: "#36383e" }
                EditorButton { text: qsTr("Open"); enabled: !backend.busy; onClicked: openVideo() }
                Label { Layout.fillWidth: true; text: win.fileName(backend.source); color: "#8f939f"; font.pixelSize: 12; elide: Text.ElideMiddle }
                EditorButton { objectName: "saveCopyButton"; text: qsTr("Save copy"); highlighted: true; enabled: win.editing; onClicked: exportVideo() }
            }
        }

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 8
            Rectangle {
                visible: win.width >= 1100
                Layout.preferredWidth: 184; Layout.fillHeight: true
                color: "#17181c"; radius: Math.min(6, theme.radius)
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 12; spacing: 12
                    Label { text: qsTr("Media"); font.pixelSize: 13; font.bold: true; color: "#e7e8eb" }
                    EditorButton { Layout.fillWidth: true; text: qsTr("Open a video"); enabled: !backend.busy; onClicked: openVideo() }
                    ScrollView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                        contentWidth: availableWidth
                        Column {
                            width: parent.width; spacing: 12
                            Repeater {
                                model: backend.videos
                                delegate: Column {
                                    required property var modelData
                                    width: 160; spacing: 6
                                    Rectangle {
                                        width: parent.width; height: 92; color: "#25272d"; border.color: "#34363e"; radius: Math.min(4, theme.radius); clip: true
                                        Image { anchors.fill: parent; anchors.margins: 1; fillMode: Image.PreserveAspectFit; asynchronous: true
                                            source: "image://thumbs/" + modelData.thumbKey + "/0"
                                        }
                                    }
                                    Label { width: parent.width; text: win.fileName(modelData.url); color: "#b9bdc7"; font.pixelSize: 11; elide: Text.ElideMiddle }
                                }
                            }
                        }
                    }
                    Label { text: qsTr("Drop a video into the window"); Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#777d8b"; font.pixelSize: 11 }
                }
            }

            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true
                color: "#17181c"; radius: Math.min(6, theme.radius)
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                    Label { text: qsTr("Preview"); color: "#cbd0d9"; font.pixelSize: 12; font.bold: true }
        // --- video preview ---
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 0
            color: "black"
            clip: true

            id: preview
            // Clip in source coordinates, then rotate the clipped image, just as export does.
            Item {
                id: cropViewport
                objectName: "cropViewport"
                anchors.centerIn: parent
                readonly property rect crop: backend.crop
                readonly property real sourceAspect: videoOut.implicitHeight > 0
                    ? videoOut.implicitWidth / videoOut.implicitHeight : 16 / 9
                readonly property real aspect: sourceAspect * crop.width / Math.max(0.01, crop.height)
                readonly property bool quarterTurn: backend.rotation % 180 !== 0
                readonly property real availableW: quarterTurn ? preview.height : preview.width
                readonly property real availableH: quarterTurn ? preview.width : preview.height
                width: Math.min(availableW, availableH * aspect)
                height: width / Math.max(0.01, aspect)
                rotation: backend.rotation
                clip: true
                VideoOutput {
                    id: videoOut
                    x: -cropViewport.crop.x * width
                    y: -cropViewport.crop.y * height
                    width: cropViewport.width / Math.max(0.01, cropViewport.crop.width)
                    height: cropViewport.height / Math.max(0.01, cropViewport.crop.height)
                    fillMode: VideoOutput.Stretch
                }
            }
            Connections {
                target: videoOut.videoSink
                function onVideoFrameChanged(frame) {
                    player.frameReady = videoOut.videoSink.videoSize.width > 0 && videoOut.videoSink.videoSize.height > 0;
                    if (player.frameReady && backend.frameCovers(videoOut.videoSink, player.primeMs))
                        player.finishPriming();
                }
            }

            // Only the empty state opens on a preview click: with a video
            // loaded, a stray click must not reach the file picker at all.
            MouseArea {
                anchors.fill: parent
                enabled: !win.hasVideo
                cursorShape: Qt.PointingHandCursor
                onClicked: openVideo()
            }

            Button {
                id: openVideoButton
                anchors.centerIn: parent
                visible: !win.hasVideo
                text: qsTr("Open a video")
                highlighted: true
                // Material.roundedScale isn't inherited, so the control sets it itself.
                Material.roundedScale: theme.radius
                focusPolicy: Qt.NoFocus
                font.pixelSize: 18
                Material.foreground: win.accentForeground
                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }
                contentItem: Label {
                    text: openVideoButton.text
                    font: openVideoButton.font
                    color: win.accentForeground
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: openVideo()
            }

            // With no video open there's no status line, so a file that
            // won't open says why here.
            Label {
                anchors.top: openVideoButton.bottom
                anchors.topMargin: 16
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, parent.width - 32)
                visible: !win.hasVideo && win.noticeText !== ""
                textFormat: Text.PlainText
                text: win.noticeText
                color: win.accent
                font.pixelSize: 13
                font.family: "monospace"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }


                    RowLayout {
                        Layout.fillWidth: true; Layout.preferredHeight: 32
                        Label { Layout.fillWidth: true; text: Format.fmt(editBar.playheadSec); color: win.accent; font.family: "monospace"; font.pixelSize: 12 }
                        IconButton { implicitWidth: 30; implicitHeight: 30; radius: Math.min(4, theme.radius); iconName: win.playing() ? "pause" : "play"; tipText: win.playing() ? qsTr("Pause") : qsTr("Play"); enabled: timeline.duration > 0; onClicked: togglePlay() }
                        Label { Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; text: Format.fmt(timeline.duration); color: "#858b98"; font.family: "monospace"; font.pixelSize: 12 }
                    }
                }
            }

            Rectangle {
                visible: win.width >= 980 && win.hasVideo
                Layout.preferredWidth: 248; Layout.fillHeight: true
                color: "#17181c"; radius: Math.min(6, theme.radius)
                ScrollView {
                    anchors.fill: parent; anchors.margins: 12; clip: true
                    contentWidth: availableWidth
                    VideoSettings { width: parent.width; compact: true; enabled: !backend.busy }
                }
            }
        }

        Rectangle {
            visible: win.hasVideo
            Layout.fillWidth: true; Layout.preferredHeight: 198
            color: "#17181c"; radius: Math.min(6, theme.radius)
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 12; spacing: 10
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    EditorButton { text: qsTr("Undo"); enabled: win.editing && timeline.canUndo; onClicked: timeline.undo() }
                    EditorButton { text: qsTr("Redo"); enabled: win.editing && timeline.canRedo; onClicked: timeline.redo() }
                    Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 20; color: "#36383e" }
                    EditorButton { objectName: "splitButton"; text: qsTr("Split"); enabled: win.editing; onClicked: timeline.split(editBar.playheadSec) }
                    EditorButton { objectName: "deleteButton"; text: qsTr("Delete"); enabled: win.editing && timeline.clips.length > 1; onClicked: timeline.removeAt(editBar.playheadSec) }
                    EditorButton { text: qsTr("Video settings"); enabled: win.hasVideo && !backend.busy; onClicked: { player.pause(); adjustmentsPanel.open() } }
                    Item { Layout.fillWidth: true }
                    EditorButton { text: "−"; enabled: win.editing; onClicked: editBar.zoomBy(0.5) }
                    EditorButton { text: "+"; enabled: win.editing; onClicked: editBar.zoomBy(2) }
                }
                RowLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true; spacing: 12
                    Rectangle {
                        Layout.preferredWidth: 68; Layout.fillHeight: true; color: "#1e2026"; border.color: "#2b2e35"
                        Label { anchors.centerIn: parent; text: qsTr("Video"); font.pixelSize: 11; color: "#8e95a4" }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 6
                        Item {
                            Layout.fillWidth: true; Layout.preferredHeight: 22
                            Repeater {
                                model: editBar.rulerCount
                                delegate: Item {
                                    required property int index
                                    readonly property real tick: editBar.rulerFirst + index * editBar.rulerStep
                                    x: editBar.xForTime(tick)
                                    width: 1; height: 22
                                    Rectangle { width: 1; height: 5; anchors.bottom: parent.bottom; color: "#4b505c" }
                                    Text { text: Format.fmt(parent.tick); color: "#777f8d"; font.pixelSize: 9; font.family: "monospace" }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onPressed: mouse => { player.pause(); seekTo(editBar.timeForX(mouse.x)) }
                                onPositionChanged: mouse => { if (pressed) seekTo(editBar.timeForX(mouse.x)) }
                                onWheel: wheel => {
                                    if (wheel.modifiers & Qt.ControlModifier) editBar.zoomBy(wheel.angleDelta.y > 0 ? 1.25 : 0.8, wheel.x)
                                    else editBar.panTo(editBar.windowStart - (wheel.angleDelta.x || wheel.angleDelta.y) / 120 * editBar.windowLen * 0.15)
                                    wheel.accepted = true
                                }
                            }
                        }
                        EditBar {
                            id: editBar; objectName: "editBar"
                            Layout.fillWidth: true; Layout.preferredHeight: 76
                            enabled: !backend.busy; accent: win.accent; accentForeground: win.accentForeground
                            onScrub: (seconds) => { win.contentItem.forceActiveFocus(); player.pause(); seekTo(seconds) }
                            onScrubClip: (index, sourceTime) => { win.contentItem.forceActiveFocus(); player.pause(); player.show(index, sourceTime, false) }
                        }
                        ScrollBar {
                            id: timelineScroll
                            objectName: "timelineScroll"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 12
                            orientation: Qt.Horizontal
                            policy: ScrollBar.AlwaysOn
                            size: Math.min(1, editBar.windowLen / Math.max(editBar.durationSec + editBar.windowLen * 0.85, editBar.windowLen))
                            position: editBar.windowStart / Math.max(editBar.durationSec + editBar.windowLen * 0.85, editBar.windowLen)
                            onActiveChanged: if (active) editBar.panTo(position * (editBar.durationSec + editBar.windowLen * 0.85))
                            onPositionChanged: if (pressed) editBar.panTo(position * (editBar.durationSec + editBar.windowLen * 0.85))
                        }
                    }
                }
            }
        }
        RowLayout {
            visible: backend.exporting; Layout.fillWidth: true
            ProgressBar { Layout.fillWidth: true; value: backend.exportProgress }
            Label { text: Math.round(backend.exportProgress * 100) + "%" }
            EditorButton { objectName: "cancelExportButton"; text: qsTr("Cancel export"); onClicked: backend.cancelExport() }
        }
        // --- status line ---
        Item {
            visible: win.hasVideo
            Layout.fillWidth: true
            Layout.preferredHeight: 26

            Label {
                anchors.centerIn: parent
                width: parent.width
                visible: win.statusText !== ""
                // ffprobe's and ffmpeg's errors are shown as they are.
                textFormat: Text.PlainText
                text: win.statusText
                color: win.noticeText !== "" ? win.accent : "#b8b8bc"
                font.pixelSize: 13
                font.family: "monospace"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideMiddle
            }

            Label {
                anchors.centerIn: parent
                visible: win.statusText === "" && timeline.duration > 0 && !editBar.trimming
                textFormat: Text.StyledText
                text: Format.fmt(editBar.playheadSec) + " (" + Format.fmt(win.timeline.duration) + ")"
                    + (editBar.zoomed ? " · <font color=\"" + win.accent + "\">" + qsTr("zoomed") + "</font>" : "")
                color: "#d6d6da"
                font.pixelSize: 13
                font.family: "monospace"
            }
        }
    }

    DropArea {
        LayoutMirroring.enabled: win.rightToLeft
        LayoutMirroring.childrenInherit: true
        id: videoDropArea
        objectName: "videoDropArea"
        anchors.fill: parent
        z: 5
        enabled: !win.overlayOpen && !backend.busy
        // Only local files: "file:-report" or "file:http://..." would reach
        // ffprobe as an option or an address, and "file:////host/..." is a
        // network share.
        onEntered: (drag) => {
            drag.accepted = drag.hasUrls && drag.urls.length > 0
                && drag.urls.every((url) => /^file:\/\/\/(?!\/)/.test(url.toString()));
        }
        onDropped: (drop) => {
            player.pause();
            player.pendingPlay = false;
            if (win.dropVideos(drop.urls))
                drop.accept(Qt.CopyAction);
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: 8
            visible: videoDropArea.containsDrag
            color: "#cc0e0e10"
            border.color: win.accent
            border.width: 2
            radius: theme.radius
            Label {
                anchors.centerIn: parent
                text: win.hasVideo ? qsTr("Drop to add to the edit") : qsTr("Drop a video to open it")
                font.pixelSize: 20
                color: win.accent
            }
        }
    }

    // --- subtle help toggle in the corner ---
    Rectangle {
        LayoutMirroring.enabled: win.rightToLeft
        LayoutMirroring.childrenInherit: true
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 10
        width: 24
        height: 24
        radius: 12
        color: helpHover.hovered ? "#2c2c2f" : "transparent"

        Text {
            anchors.centerIn: parent
            text: "?"
            color: helpHover.hovered ? "white" : "#7a7a80"
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }
        HoverHandler {
            id: helpHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: win.helpVisible = !win.helpVisible
        }
    }

    // --- hotkey overlay ---
    Rectangle {
        LayoutMirroring.enabled: win.rightToLeft
        LayoutMirroring.childrenInherit: true
        visible: win.helpVisible
        anchors.fill: parent
        color: "#cc000000"

        MouseArea {
            anchors.fill: parent
            onClicked: win.helpVisible = false
        }

        DialogPanel {
            anchors.centerIn: parent
            width: helpColumn.width + 56
            height: helpColumn.height + 48

            Column {
                id: helpColumn
                anchors.centerIn: parent
                spacing: 10

                Label {
                    text: qsTr("Keyboard shortcuts")
                    color: "white"
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                    bottomPadding: 8
                }

                Repeater {
                    model: [
                        { keys: "Space", action: qsTr("Play / pause") },
                        { keys: "0–9", action: qsTr("Jump to 0%–90% of the edit") },
                        { keys: "← / →", action: qsTr("One frame when paused; 1s while playing") },
                        { keys: "Shift ← / →", action: qsTr("Move playhead 5s") },
                        { keys: "Alt ← / →", action: qsTr("One frame; hold to move 0.2s") },
                        { keys: "[ / ]", action: qsTr("Previous / next clip edge") },
                        { keys: "S", action: qsTr("Split the clip at the playhead") },
                        { keys: "X", action: qsTr("Remove the clip") },
                        { keys: "Alt [ / ]", action: qsTr("Move the clip earlier / later") },
                        { keys: "Ctrl Space", action: qsTr("Clip start to playhead") },
                        { keys: "Ctrl Shift Space", action: qsTr("Clip end to playhead") },
                        { keys: "Ctrl Z", action: qsTr("Undo (Ctrl Shift Z redo)") },
                        { keys: "Z", action: qsTr("Zoom to the clip") },
                        { keys: "F", action: qsTr("Save the playhead frame as a PNG") },
                        { keys: "Ctrl O", action: qsTr("Open a video") },
                        { keys: "Ctrl Shift O", action: qsTr("Add a video after this clip") },
                        { keys: "Ctrl S", action: qsTr("Export") },
                        { keys: "Q", action: qsTr("Quit") },
                        { keys: "?", action: qsTr("Show these shortcuts") }
                    ]
                    delegate: Row {
                        spacing: 18
                        Label {
                            width: 110
                            horizontalAlignment: Text.AlignRight
                            text: modelData.keys
                            color: win.accent
                            font.pixelSize: 13
                            font.family: "monospace"
                        }
                        Label {
                            text: modelData.action
                            color: "#d6d6da"
                            font.pixelSize: 13
                        }
                    }
                }
            }
        }
    }

    AdjustmentsPanel {
        id: adjustmentsPanel
        objectName: "adjustmentsPanel"
        parent: Overlay.overlay
        x: Math.max(0, (win.width - width) / 2)
        y: Math.max(0, (win.height - height) / 2)
        width: Math.min(560, win.width - 32)
    }

    // --- open confirmation (replacing an unexported edit) ---
    ConfirmDialog {
        visible: win.openConfirmVisible
        title: qsTr("Unexported edit")
        message: qsTr("Opening another video will discard this edit. Open it anyway?")
        buttons: [
            { text: qsTr("Keep editing"), mnemonic: "K" },
            { text: qsTr("Open video"), mnemonic: "O", primary: true }
        ]
        onDismissed: win.openConfirmVisible = false
        onChosen: (index) => {
            win.openConfirmVisible = false;
            if (index === 1)
                backend.openVideoDialog();
        }
    }

    // --- quit confirmation ---
    ConfirmDialog {
        visible: win.quitConfirmVisible
        title: backend.exporting ? qsTr("Exporting") : qsTr("Unexported edit")
        message: backend.exporting ? qsTr("The export is still running, and quitting stops it. Quit anyway?")
                                   : qsTr("Your edit hasn't been exported. Quit anyway?")
        // Already exporting: there's nothing to start, so no Export.
        buttons: [
            { text: qsTr("Cancel"), mnemonic: "C" },
            { text: qsTr("Quit"), mnemonic: "Q" }
        ].concat(backend.exporting ? [] : [{ text: qsTr("Export"), mnemonic: "E", primary: true }])
        initialFocus: backend.exporting ? 0 : 2
        onDismissed: win.quitConfirmVisible = false
        onChosen: (index) => {
            win.quitConfirmVisible = false;
            if (index === 1)
                forceQuit();
            else if (index === 2)
                exportVideo();
        }
    }

    Connections {
        target: backend
        function onFrameStepped(from, to) {
            if (win.editing && !win.playing() && Math.abs(editBar.playheadSec - from) < 0.000001)
                win.seekTo(to);
        }
        function onInfoChanged() {
            win.noticeText = "";
            noticeTimer.stop();
            // Drop any prime or load still pending for the last video.
            primeFallback.stop();
            player.priming = false;
            player.frameReady = false;
            player.pendingMs = -1;
            // Load afresh, even the same path: it may be a new file now.
            player.source = "";
            editBar.zoomed = false;
            editBar.playheadSec = 0;
            if (win.hasVideo)
                player.show(0, 0, false);
        }
        function onExportDone(path) {
            win.showNotice(qsTr("Saved %1").arg(path));
        }
        function onExportCancelled() {
            win.showNotice(qsTr("Export cancelled"));
        }
        function onExportFailed(message) {
            win.showNotice(qsTr("Export failed: %1").arg(message));
        }
        function onFrameSaved(path) {
            win.showNotice(qsTr("Saved %1").arg(path));
        }
        function onFrameFailed(message) {
            win.showNotice(qsTr("Could not save the frame: %1").arg(message));
        }
        function onFrameStepFailed(message) {
            win.showNotice(qsTr("Could not step to the frame: %1").arg(message));
        }
        function onLoadError(message) {
            win.showNotice(qsTr("Cannot open video: %1").arg(message));
        }
        function onExportReopenFailed() {
            win.showNotice(qsTr("Saved, but couldn't reopen it, so the clips no longer match the file."));
        }
        function onSkippedVideos(count) {
            win.showNotice(qsTr("Skipped %n files that won't open.", "", count));
        }
    }
}
