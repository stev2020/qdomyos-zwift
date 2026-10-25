import QtQuick 2.7
import QtQuick.Controls 2.15
import Qt.labs.settings 1.0
import QtWebView 1.1

// FunRun pages (ride end screen, ride history): web pages of the app's own web server,
// folder inner_templates/funrun. They talk to the app over the template web socket (/funrun-ws).
Item {
    id: funrunPage
    objectName: "funrunPage"
    property string page: "ende.htm"
    property string rideId: ""
    property string from: ""

    Settings {
        id: settings
    }

    function pageUrl() {
        // query string: never a cached page from before an app update
        return "http://localhost:" + settings.value("template_inner_QZWS_port") + "/funrun/" + page +
               "?id=" + encodeURIComponent(rideId) + (from !== "" ? "&from=" + from : "") + "&v=" + Date.now()
    }

    // shows another FunRun page here instead of stacking a new one
    function open(newPage, newRideId, newFrom) {
        page = newPage
        rideId = newRideId
        from = newFrom || ""
        webView.url = pageUrl()
    }

    WebView {
        id: webView
        anchors.fill: parent
        onLoadingChanged: {
            if (loadRequest.errorString)
                console.error("FunRun page: " + loadRequest.errorString)
        }
    }

    // "Fertig" or "×" on the page: back to the start page, or one page back (opened from the history)
    Connections {
        target: rootItem
        ignoreUnknownSignals: true
        function onFunrunCloseRequested(to) {
            if (stackView.currentItem !== funrunPage)
                return
            if (to === "back")
                stackView.pop()
            else
                stackView.pop(null)
        }
    }

    // as after the old chart page: the workout summary mail goes out if it is set up
    Timer {
        interval: 10000
        running: funrunPage.page === "ende.htm" && funrunPage.from === ""
        repeat: false
        onTriggered: rootItem.sendMail()
    }

    Component.onCompleted: {
        headerToolbar.visible = true
        webView.url = pageUrl()
    }
}
