#ifndef FUNRUNMOVE_H
#define FUNRUNMOVE_H

#include <QJsonObject>
#include <QString>

/**
 * FunRun as an app of its own (shown as Kvestrun, not final; codename QuestRun: Android id io.github.stev2020.questrun)
 * next to the QZ app it grew out of:
 * - it keeps its files in its own folder (Documents/QuestRun on Android 14+, QZ: Documents/QZ; the folder stays with
 *   the codename when the shown name changes) and runs its web server on its own port, so both apps can be installed,
 *   and even run, at the same time;
 * - moving: the QZ app packs rides, routes, workouts, training programs, profiles, its settings and the storage of the
 *   FunRun pages into one file (Download/Kvestrun-Umzug.zip). The new app takes that file (picked by the user) and
 *   unpacks it at its next start, before anything reads the settings.
 */
namespace FunRunMove {

// Android package of this app ("org.cagnulen.qdomyoszwift" for the QZ app, and on the other systems)
QString packageName();
// the QZ app (its id, its folder, its port); false for the FunRun app with its own id
bool isQzApp();
// name of the app's folder in Documents (Android 14+): "QZ" or "QuestRun"
QString documentsFolder();
// folder, private to the app, where the file picker puts a moving file and where the move keeps its notes
QString incomingFolder();

// At start, right after the application's name is set: the FunRun app gets its own web server port, and a moving
// file kept at the last start is unpacked now
void prepare();

// Packs the moving file. pages: the storage of the FunRun pages (JSON text of their localStorage).
// Returns { ok, file, size, rides, routes, workouts, settings, error }
QJsonObject pack(const QString &pages);
// What a moving file holds: { ok, created, from, rides, routes, workouts, settings, error }
QJsonObject inspect(const QString &file);
// Keeps an inspected moving file: it is unpacked at the next start. Returns { ok, error }
QJsonObject schedule(const QString &file);
// Unpacks a moving file into this app: settings, files, the pages' storage (kept for takePages).
// Returns { ok, rides, routes, workouts, settings, files, error }
QJsonObject unpack(const QString &file);

// The storage of the FunRun pages brought along by the last move, once (an empty string afterwards)
QString takePages();
// The result of the last unpacking, once (an empty object afterwards)
QJsonObject takeResult();

} // namespace FunRunMove

#endif // FUNRUNMOVE_H
