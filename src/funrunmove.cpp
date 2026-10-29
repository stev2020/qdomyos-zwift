#include "funrunmove.h"
#include "homeform.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMutex>
#include <QMutexLocker>
#include <QSettings>
#include <QStandardPaths>
#include <QTcpServer>
#include <private/qzipreader_p.h>
#include <private/qzipwriter_p.h>

#ifdef Q_OS_ANDROID
#include <QAndroidJniEnvironment>
#include <QAndroidJniObject>
#include <QtAndroid>
#endif

namespace {

const QString qzPackage = QStringLiteral("org.cagnulen.qdomyoszwift");
// the moving file and what it holds
const QString moveFileName = QStringLiteral("Kvestrun-Umzug.zip");
const QString moveFormat = QStringLiteral("funrun-umzug");
const QString manifestEntry = QStringLiteral("funrun-umzug.json");
const QString settingsEntry = QStringLiteral("einstellungen.ini");
const QString pagesEntry = QStringLiteral("seiten.json");
const QString filesPrefix = QStringLiteral("dateien/");
// notes of the move in the app's private folder
const QString pendingName = QStringLiteral("pending.zip");
const QString pagesName = QStringLiteral("seiten.json");
const QString resultName = QStringLiteral("ergebnis.json");
// the port of the FunRun app's web server (QZ: a free one, picked at every start); the old app's port setting does not
// move along
const QString portKey = QStringLiteral("template_inner_QZWS_port");
const int funrunPort = 6680;

// the folders of the app folder that move along, with all their files
const QStringList movedFolders = {QStringLiteral("funrun"),   QStringLiteral("gpx"),      QStringLiteral("fit"),
                                  QStringLiteral("training"), QStringLiteral("profiles"), QStringLiteral("settings"),
                                  QStringLiteral("QZTemplates")};

// files that stay: the routes' list is only a cache (it holds the old paths and is made again), the move's own
// notes, and files too big to be anything of the rides
bool staysBehind(const QString &relative, qint64 size) {
    if (relative == QStringLiteral("funrun/routes.json"))
        return true;
    if (QFileInfo(relative).fileName().startsWith(QStringLiteral("umzug-")))
        return true;
    return size > 200LL * 1024 * 1024;
}

// files whose text may hold paths of the old app folder (rides, multi-day routes, profiles)
bool holdsPaths(const QString &relative) {
    const QString suffix = QFileInfo(relative).suffix().toLower();
    return suffix == QStringLiteral("json") || suffix == QStringLiteral("qzs");
}

bool isUnder(const QString &relative, const QString &folder, const QString &suffix) {
    return relative.startsWith(folder) && relative.endsWith(suffix, Qt::CaseInsensitive);
}

struct Counts {
    int rides = 0, routes = 0, workouts = 0;
    void add(const QString &relative) {
        if (isUnder(relative, QStringLiteral("funrun/rides/"), QStringLiteral(".json")))
            rides++;
        else if (isUnder(relative, QStringLiteral("gpx/"), QStringLiteral(".gpx")))
            routes++;
        else if (isUnder(relative, QStringLiteral("funrun/ultra/"), QStringLiteral(".json")))
            routes++;
        else if (isUnder(relative, QStringLiteral("fit/"), QStringLiteral(".fit")))
            workouts++;
    }
    void into(QJsonObject &o) const {
        o[QStringLiteral("rides")] = rides;
        o[QStringLiteral("routes")] = routes;
        o[QStringLiteral("workouts")] = workouts;
    }
};

QJsonObject failed(const QString &error) {
    QJsonObject o;
    o[QStringLiteral("ok")] = false;
    o[QStringLiteral("error")] = error;
    return o;
}

bool writeFile(const QString &path, const QByteArray &data) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    const bool ok = f.write(data) == data.size();
    f.close();
    return ok && f.error() == QFileDevice::NoError;
}

QByteArray readFile(const QString &path) {
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

// the folders the old app kept its files in (its folder, and on Android its first folder before Documents)
QStringList appFolders() {
    QStringList folders;
    folders << homeform::getWritableAppDir();
#ifdef Q_OS_ANDROID
    const QString dataDir = homeform::getAndroidDataAppDir();
    if (!dataDir.isEmpty() && !folders.contains(dataDir + QStringLiteral("/")))
        folders << dataDir + QStringLiteral("/");
#endif
    return folders;
}

// a path of an old folder becomes the same path in the new one
QString rebase(QString text, const QStringList &oldFolders, const QString &newFolder) {
    for (const QString &old : oldFolders)
        if (!old.isEmpty() && old != newFolder)
            text.replace(old, newFolder);
    return text;
}

QByteArray rebase(QByteArray data, const QStringList &oldFolders, const QString &newFolder) {
    for (const QString &old : oldFolders)
        if (!old.isEmpty() && old != newFolder)
            data.replace(old.toUtf8(), newFolder.toUtf8());
    return data;
}

QJsonObject manifestOf(QZipReader &zip) {
    const QJsonDocument doc = QJsonDocument::fromJson(zip.fileData(manifestEntry));
    const QJsonObject m = doc.object();
    return m.value(QStringLiteral("format")).toString() == moveFormat ? m : QJsonObject();
}

} // namespace

QString FunRunMove::packageName() {
#ifdef Q_OS_ANDROID
    static QMutex mutex;
    static QString name;
    QMutexLocker lock(&mutex);
    if (name.isEmpty()) {
        const QAndroidJniObject context = QtAndroid::androidContext();
        if (context.isValid())
            name = context.callObjectMethod("getPackageName", "()Ljava/lang/String;").toString();
        QAndroidJniEnvironment env;
        if (env->ExceptionCheck())
            env->ExceptionClear();
    }
    return name.isEmpty() ? qzPackage : name;
#else
    return qzPackage;
#endif
}

bool FunRunMove::isQzApp() { return packageName() == qzPackage; }

QString FunRunMove::documentsFolder() { return isQzApp() ? QStringLiteral("QZ") : QStringLiteral("QuestRun"); }

QString FunRunMove::incomingFolder() {
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + QStringLiteral("/umzug/");
    QDir().mkpath(dir);
    return dir;
}

int FunRunMove::webServerPort() {
    if (isQzApp())
        return 0;
    QTcpServer probe;
    if (!probe.listen(QHostAddress::Any, funrunPort))
        return 0;
    probe.close();
    return funrunPort;
}

void FunRunMove::prepare() {
    const QString pending = incomingFolder() + pendingName;
    if (!QFile::exists(pending))
        return;
    QJsonObject result = unpack(pending);
    QFile::remove(pending);
    result[QStringLiteral("date")] = QDateTime::currentDateTime().toString(Qt::ISODate);
    writeFile(incomingFolder() + resultName, QJsonDocument(result).toJson(QJsonDocument::Compact));
    qDebug() << "FunRunMove: unpacked" << result;
}

QJsonObject FunRunMove::pack(const QString &pages) {
    const QStringList folders = appFolders();
    const QString base = folders.first();

    // the settings as the app keeps them
    QSettings settings;
    settings.sync();
    const QByteArray ini = readFile(settings.fileName());
    const int settingsCount = settings.allKeys().size();

    QStringList files;
    Counts counts;
    for (const QString &folder : movedFolders) {
        QDirIterator it(base + folder, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString path = it.next();
            const QString relative = path.mid(base.size());
            if (staysBehind(relative, it.fileInfo().size()))
                continue;
            files << relative;
            counts.add(relative);
        }
    }

    QJsonObject manifest;
    manifest[QStringLiteral("format")] = moveFormat;
    manifest[QStringLiteral("version")] = 1;
    manifest[QStringLiteral("created")] = QDateTime::currentDateTime().toString(Qt::ISODate);
    manifest[QStringLiteral("from")] = packageName();
    manifest[QStringLiteral("folders")] = QJsonArray::fromStringList(folders);
    manifest[QStringLiteral("settings")] = settingsCount;
    manifest[QStringLiteral("files")] = files.size();
    counts.into(manifest);

    // Download first: the other app can take the file from there with the file picker
    QStringList targets;
    targets << QStandardPaths::writableLocation(QStandardPaths::DownloadLocation)
            << QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation) << base;
    QString lastError = QStringLiteral("Kein Ordner zum Speichern gefunden");
    for (const QString &target : targets) {
        if (target.isEmpty())
            continue;
        QDir().mkpath(target);
        const QString path = QDir(target).filePath(moveFileName);
        QFile::remove(path);
        QFile out(path);
        if (!out.open(QIODevice::WriteOnly)) {
            lastError = out.errorString();
            continue;
        }
        bool ok = true;
        {
            QZipWriter zip(&out);
            zip.addFile(manifestEntry, QJsonDocument(manifest).toJson());
            if (!ini.isEmpty())
                zip.addFile(settingsEntry, ini);
            zip.addFile(pagesEntry, pages.toUtf8());
            for (const QString &relative : files) {
                QFile f(base + relative);
                if (f.open(QIODevice::ReadOnly))
                    zip.addFile(filesPrefix + relative, &f);
            }
            zip.close();
            ok = zip.status() == QZipWriter::NoError;
        }
        if (!ok || out.error() != QFileDevice::NoError) {
            lastError = out.errorString();
            QFile::remove(path);
            continue;
        }
        QJsonObject result;
        result[QStringLiteral("ok")] = true;
        result[QStringLiteral("file")] = path;
        result[QStringLiteral("size")] = QFileInfo(path).size();
        result[QStringLiteral("settings")] = settingsCount;
        counts.into(result);
        return result;
    }
    return failed(lastError);
}

QJsonObject FunRunMove::inspect(const QString &file) {
    QZipReader zip(file);
    if (!zip.isReadable() || zip.status() != QZipReader::NoError)
        return failed(QStringLiteral("Die Datei lässt sich nicht lesen."));
    const QJsonObject m = manifestOf(zip);
    if (m.isEmpty())
        return failed(QStringLiteral("Das ist keine Umzugsdatei."));
    QJsonObject result;
    result[QStringLiteral("ok")] = true;
    result[QStringLiteral("file")] = file;
    for (const QString &key : {QStringLiteral("created"), QStringLiteral("from"), QStringLiteral("rides"),
                               QStringLiteral("routes"), QStringLiteral("workouts"), QStringLiteral("settings")})
        result[key] = m.value(key);
    return result;
}

QJsonObject FunRunMove::schedule(const QString &file) {
    const QJsonObject check = inspect(file);
    if (!check.value(QStringLiteral("ok")).toBool())
        return check;
    const QString pending = incomingFolder() + pendingName;
    QFile::remove(pending);
    const bool ok = QFileInfo(file).absoluteFilePath() == QFileInfo(pending).absoluteFilePath() ||
                    QFile::rename(file, pending) || QFile::copy(file, pending);
    if (!ok)
        return failed(QStringLiteral("Die Umzugsdatei ließ sich nicht ablegen."));
    QJsonObject result;
    result[QStringLiteral("ok")] = true;
    return result;
}

QJsonObject FunRunMove::unpack(const QString &file) {
    QZipReader zip(file);
    if (!zip.isReadable() || zip.status() != QZipReader::NoError)
        return failed(QStringLiteral("Die Umzugsdatei lässt sich nicht lesen."));
    const QJsonObject m = manifestOf(zip);
    if (m.isEmpty())
        return failed(QStringLiteral("Das ist keine Umzugsdatei."));
    QStringList oldFolders;
    for (const QJsonValue &v : m.value(QStringLiteral("folders")).toArray())
        oldFolders << v.toString();

    // 1. the settings, all but this app's web server port. They come first: they say where the app keeps its files.
    QSettings settings;
    int settingsCount = 0;
    const QByteArray ini = zip.fileData(settingsEntry);
    if (!ini.isEmpty()) {
        const QString iniFile = incomingFolder() + settingsEntry;
        writeFile(iniFile, ini);
        {
            QSettings old(iniFile, QSettings::IniFormat);
            const QStringList keys = old.allKeys();
            for (const QString &key : keys) {
                if (key == portKey)
                    continue;
                settings.setValue(key, old.value(key));
                settingsCount++;
            }
        }
        QFile::remove(iniFile);
        settings.sync();
    }
    const QString base = homeform::getWritableAppDir();
    // paths in the settings (the chosen route, the last training program, ...) point into the new folder
    for (const QString &key : settings.allKeys()) {
        const QVariant value = settings.value(key);
        if (value.type() == QVariant::String) {
            const QString moved = rebase(value.toString(), oldFolders, base);
            if (moved != value.toString())
                settings.setValue(key, moved);
        } else if (value.type() == QVariant::StringList) {
            QStringList list = value.toStringList();
            bool changed = false;
            for (QString &s : list) {
                const QString moved = rebase(s, oldFolders, base);
                changed = changed || moved != s;
                s = moved;
            }
            if (changed)
                settings.setValue(key, list);
        }
    }
    settings.sync();

    // 2. the files, only inside the app's folder
    const QString root = QDir::cleanPath(base) + QStringLiteral("/");
    Counts counts;
    int written = 0, failures = 0;
    for (const QZipReader::FileInfo &info : zip.fileInfoList()) {
        if (!info.isFile || !info.filePath.startsWith(filesPrefix))
            continue;
        const QString relative = info.filePath.mid(filesPrefix.size());
        const QString target = QDir::cleanPath(base + relative);
        if (!target.startsWith(root))
            continue;
        QByteArray data = zip.fileData(info.filePath);
        if (holdsPaths(relative))
            data = rebase(data, oldFolders, base);
        if (writeFile(target, data)) {
            written++;
            counts.add(relative);
        } else {
            failures++;
        }
    }

    // 3. the storage of the FunRun pages, for the first page that opens
    const QByteArray pages = zip.fileData(pagesEntry);
    if (!pages.trimmed().isEmpty())
        writeFile(incomingFolder() + pagesName, pages);

    QJsonObject result;
    result[QStringLiteral("ok")] = failures == 0;
    if (failures)
        result[QStringLiteral("error")] = QStringLiteral("%1 Dateien ließen sich nicht schreiben.").arg(failures);
    result[QStringLiteral("settings")] = settingsCount;
    result[QStringLiteral("files")] = written;
    result[QStringLiteral("created")] = m.value(QStringLiteral("created"));
    counts.into(result);
    return result;
}

QString FunRunMove::takePages() {
    const QString path = incomingFolder() + pagesName;
    const QByteArray data = readFile(path);
    QFile::remove(path);
    return QString::fromUtf8(data);
}

QJsonObject FunRunMove::takeResult() {
    const QString path = incomingFolder() + resultName;
    const QJsonObject result = QJsonDocument::fromJson(readFile(path)).object();
    QFile::remove(path);
    return result;
}
