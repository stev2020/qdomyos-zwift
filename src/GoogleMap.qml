import QtQuick 2.7
import QtQuick.Layouts 1.3
import QtQuick.Controls 2.15
import QtQuick.Controls.Material 2.0
import Qt.labs.settings 1.0
import QtWebView 1.1

ColumnLayout {
    signal popupclose()
    id: column1
    spacing: 0
    anchors.fill: parent
    Settings {
        id: settings
        property string maps_type: "3D"
    }
    readonly property string mapUrl: "http://localhost:" + settings.value("template_inner_QZWS_port") + "/" +
                                     (settings.value("maps_type") === "3D" ? "googlemaps" : "maps2d") + "/maps.htm"
    property int diagChecks: 0

    // Load state and diagnostics. Kept above the web view: the native web view covers anything on top of it.
    RowLayout {
        id: statusBar
        Layout.fillWidth: true
        visible: statusLabel.text !== ""
        spacing: 8
        Label {
            id: statusLabel
            Layout.fillWidth: true
            Layout.leftMargin: 8
            wrapMode: Text.WordWrap
            text: ""
        }
        Button {
            text: qsTr("Neu laden")
            onClicked: column1.loadMap(true)
        }
    }

    WebView {
        id: webView
        Layout.fillWidth: true
        Layout.fillHeight: true
        onLoadingChanged: {
            if (loadRequest.status === WebView.LoadStartedStatus) {
                statusLabel.text = qsTr("Karte wird geladen …");
            } else if (loadRequest.status === WebView.LoadSucceededStatus) {
                statusLabel.text = qsTr("Seite geladen, Karte startet …");
                column1.diagChecks = 0;
                diagTimer.restart();
            } else if (loadRequest.status === WebView.LoadFailedStatus) {
                statusLabel.text = qsTr("Karte konnte nicht geladen werden: ") + loadRequest.errorString;
                console.error("map load failed " + loadRequest.errorString + " " + loadRequest.url);
            }
        }
    }

    // Start loading only once the page is on screen: a web view that starts loading while it is still
    // hidden inside the Loader can stay white on Android. "Neu laden" forces a fresh load.
    // Every load gets a new query string, otherwise the web view keeps cached copies of the page
    // (and of its key file) from before an app update.
    function loadMap(force) {
        if (force || webView.url.toString().indexOf(column1.mapUrl) !== 0) {
            webView.url = column1.mapUrl + "?v=" + Date.now();
        }
    }

    Timer {
        id: loadTimer
        interval: 300
        onTriggered: column1.loadMap(false)
    }

    // Ask the page how far it got (window.qzmapDiag in googlemaps/maps.htm) and show problems in the status line
    Timer {
        id: diagTimer
        interval: 2000
        repeat: true
        onTriggered: {
            column1.diagChecks++;
            webView.runJavaScript("JSON.stringify(window.qzmapDiag || null)", function(result) {
                var d = null;
                try { d = JSON.parse(result); } catch (e) { d = null; }
                if (!d) {
                    statusLabel.text = qsTr("Seite geladen, aber das Karten-Skript läuft nicht.");
                } else if (d.error) {
                    statusLabel.text = qsTr("Fehler in der Karte: ") + d.error + " (" + d.stage + ")";
                } else if (column1.diagChecks >= 8) {
                    statusLabel.text = "";
                    diagTimer.stop();
                } else {
                    statusLabel.text = qsTr("Karte: ") + d.stage + (d.status ? " – " + d.status : "");
                }
            });
            if (column1.diagChecks >= 15)
                diagTimer.stop();
        }
    }

    // Opened again later: load fresh, so a page that stayed white the first time gets another chance
    StackView.onActivated: {
        if (webView.url.toString().indexOf(column1.mapUrl) === 0)
            column1.loadMap(true);
        else
            loadTimer.restart();
    }

    Component.onCompleted: {
        headerToolbar.visible = true;
        loadTimer.restart();
    }
}
