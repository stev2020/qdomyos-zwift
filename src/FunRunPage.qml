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

    // The app's browser above the page, for sites that let only browsers in (DotWatcher, the trackers of
    // FollowMyChallenge). The page asks for it with its title "FunRun browse <n> <url> <hint>" (FR.browse in
    // funrun.js). "Übernehmen" in the bar runs uebernahme.js in the site's page, waits for what it reads
    // (window.__funrunTake) and hands it to the page (window.funrunHandoff).
    property bool browsing: false
    property string browseUrl: ""
    property string browseHint: ""
    property string browseTitle: ""
    property bool taking: false
    property int takePolls: 0

    Settings {
        id: settings
    }

    function serverUrl() {
        return "http://localhost:" + settings.value("template_inner_QZWS_port") + "/funrun/"
    }

    function pageUrl() {
        // query string: never a cached page from before an app update
        return serverUrl() + page + "?id=" + encodeURIComponent(rideId) + (from !== "" ? "&from=" + from : "") + "&v=" + Date.now()
    }

    // shows another FunRun page here instead of stacking a new one
    function open(newPage, newRideId, newFrom) {
        closeBrowser()
        page = newPage
        rideId = newRideId
        from = newFrom || ""
        webView.url = pageUrl()
    }

    // the page's title: a request for the browser?
    function checkBrowse(t) {
        var p = "FunRun browse "
        if (!t || t.indexOf(p) !== 0) {
            browseTitle = ""
            return
        }
        if (browsing || t === browseTitle)
            return
        browseTitle = t
        var rest = t.substring(p.length)
        var a = rest.indexOf(" ")
        var b = a >= 0 ? rest.indexOf(" ", a + 1) : -1
        var url = a < 0 ? "" : (b < 0 ? rest.substring(a + 1) : rest.substring(a + 1, b))
        if (url.indexOf("https://") !== 0)
            return
        browseUrl = url
        browseHint = b < 0 ? "" : rest.substring(b + 1)
        taking = false
        browsing = true
        webView.runJavaScript("window.funrunBrowseOpened && window.funrunBrowseOpened()")
    }

    function closeBrowser() {
        takeTimer.stop()
        browseLoadTimer.stop()
        taking = false
        browsing = false
        browseUrl = ""
    }

    // Android's back key: in the browser one page back, from its first page back to the FunRun page
    function handleBack() {
        if (!browsing)
            return false
        if (browser.item && browser.item.canGoBack)
            browser.item.goBack()
        else
            closeBrowser()
        return true
    }

    function take() {
        if (taking || !browser.item)
            return
        taking = true
        browseHint = "Wird übernommen …"
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || !funrunPage.browsing)
                return
            if (xhr.status !== 200 || !browser.item) {
                funrunPage.taking = false
                funrunPage.browseHint = "Das hat nicht geklappt, versuch es noch einmal."
                return
            }
            browser.item.runJavaScript("window.__funrunTake = null;\n" + xhr.responseText)
            funrunPage.takePolls = 0
            takeTimer.start()
        }
        xhr.open("GET", serverUrl() + "uebernahme.js?v=" + Date.now())
        xhr.send()
    }

    function taken(r) {
        if (!taking || !r)
            return
        var t = null
        try { t = JSON.parse(r) } catch (e) { t = null }
        if (!t)
            return
        if (t.state === "busy") {
            if (t.text)
                browseHint = t.text
            return
        }
        takeTimer.stop()
        taking = false
        if (t.state !== "done" || !t.data) {
            browseHint = t.text || "Das hat nicht geklappt."
            return
        }
        var data = JSON.stringify(t.data)
        closeBrowser()
        webView.runJavaScript("window.funrunHandoff && window.funrunHandoff(" + data + ")")
    }

    WebView {
        id: webView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: browseBar.top
        visible: !funrunPage.browsing
        onLoadingChanged: {
            if (loadRequest.errorString)
                console.error("FunRun page: " + loadRequest.errorString)
        }
        onTitleChanged: funrunPage.checkBrowse(title)
    }

    // in case the web view does not report title changes: read the title once a second (the routes page asks for the
    // browser; the pages switch inside this web view, see FR.go)
    Timer {
        interval: 1000
        repeat: true
        running: !funrunPage.browsing && webView.url.toString().indexOf("/funrun/strecken.htm") >= 0
        onTriggered: webView.runJavaScript("document.title", function(result) { funrunPage.checkBrowse(result) })
    }

    // the browser, made only while it is open
    Loader {
        id: browser
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: browseBar.top
        active: funrunPage.browsing
        sourceComponent: Component {
            WebView {}
        }
        // a web view that starts loading while it is not yet on screen can stay white on Android (see GoogleMap.qml)
        onLoaded: browseLoadTimer.restart()
    }

    Timer {
        id: browseLoadTimer
        interval: 300
        onTriggered: if (browser.item && funrunPage.browseUrl !== "") browser.item.url = funrunPage.browseUrl
    }

    Timer {
        id: takeTimer
        interval: 400
        repeat: true
        onTriggered: {
            if (!funrunPage.browsing || !browser.item) {
                stop()
                funrunPage.taking = false
                return
            }
            funrunPage.takePolls++
            if (funrunPage.takePolls > 150) {
                stop()
                funrunPage.taking = false
                funrunPage.browseHint = "Das dauert zu lange, versuch es noch einmal."
                return
            }
            browser.item.runJavaScript("window.__funrunTake ? JSON.stringify(window.__funrunTake) : ''",
                                       function(result) { funrunPage.taken(result) })
        }
    }

    // the browser's bar: back to the FunRun page, what to do, "Übernehmen"
    Rectangle {
        id: browseBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: funrunPage.browsing ? 68 : 0
        visible: funrunPage.browsing
        color: "#121a24"

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: "#1e2833"
        }

        Rectangle {
            id: backButton
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: backLabel.implicitWidth + 28
            height: 46
            radius: 12
            color: "transparent"
            border.color: "#2a3542"
            border.width: 1
            Text {
                id: backLabel
                anchors.centerIn: parent
                text: "‹ FunRun"
                color: "#f3f5f7"
                font.pixelSize: 16
                font.bold: true
            }
            MouseArea {
                anchors.fill: parent
                onClicked: funrunPage.closeBrowser()
            }
        }

        Rectangle {
            id: takeButton
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: takeLabel.implicitWidth + 32
            height: 46
            radius: 12
            color: funrunPage.taking ? "#8a4512" : "#ff7a1a"
            Text {
                id: takeLabel
                anchors.centerIn: parent
                text: "Übernehmen"
                color: "#1a0f05"
                font.pixelSize: 16
                font.bold: true
            }
            MouseArea {
                anchors.fill: parent
                onClicked: funrunPage.take()
            }
        }

        Text {
            anchors.left: backButton.right
            anchors.right: takeButton.left
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: funrunPage.browseHint
            color: "#c9d2db"
            font.pixelSize: 14
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
        }
    }

    // "Fertig" or "×" on the page: back to the start page, or one page back (opened from the history)
    Connections {
        target: rootItem
        ignoreUnknownSignals: true
        function onFunrunCloseRequested(to) {
            if (stackView.currentItem !== funrunPage)
                return
            if (to === "back") {
                stackView.pop()
                return
            }
            // "home": back to the FunRun start page if it is open below, otherwise to the tiles
            var start = stackView.find(function(item) { return item.objectName === "funrunPage" && item.page === "start.htm" })
            if (start && start !== funrunPage)
                stackView.pop(start)
            else
                stackView.pop(null)
        }
        // a GPX file was imported (FunRun "GPX importieren"): it becomes the chosen route and the page shows it
        function onAndroidDocumentPicked(kind, localUrl) {
            if (stackView.currentItem !== funrunPage || kind !== "gpx")
                return
            var path = localUrl.toString()
            if (path.indexOf("file://") === 0)
                path = path.substring(7)
            settings.setValue("funrun_selected_route", decodeURIComponent(path))
            webView.runJavaScript("window.funrunRefresh && window.funrunRefresh()")
        }
    }

    // back on this page (after a ride, after the settings): fresh numbers
    StackView.onActivated: {
        if (webView.url.toString() !== "")
            webView.runJavaScript("window.funrunRefresh && window.funrunRefresh()")
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
