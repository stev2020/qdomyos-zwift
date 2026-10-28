# Kvest Stilprobe

Eine Probe für den Look der Welt von Kvest, gebaut mit [Godot](https://godotengine.org) 4.7. Vorbild ist der Stil von Wilderless: Meadowfell. Die Probe zeigt einen endlosen Weg durch Sommerwiesen mit einem Bach, Laubbäumen, Tannen und Blumenfeldern, bei Sommertag oder Abendsonne.

Die Probe ist eine eigene App (`io.github.stev2020.kveststilprobe`) und läuft neben Kvestrun. Das Tempo holt sie sich von Kvestrun auf demselben Tablet. Dafür verbindet sie sich mit dem eingebauten Webserver von Kvestrun (Port 6680) oder QZ (Port 6666), der jede Sekunde die Werte der Fahrt schickt. Ohne Kvestrun fährt sie im Demo-Tempo, das man unten links einstellt.

APK: https://github.com/stev2020/qdomyos-zwift/releases/download/kvest-stilprobe/kvest-stilprobe.apk

## So ist sie gebaut

- **Gras:** Büschel aus sechs sich kreuzenden Flächen (12 Dreiecke) mit gemalten Grashalmen. Es gibt sechs Sorten: üppig, mit Samen, kurz, mit Blüten, mit lila Rispen und Schilf am Bach.
- **Bäume und Büsche:** Blätterbüschel aus drei sich kreuzenden Flächen mit gemalten Blättern und deren Normalen. Arten: Buche, Birke, Eiche, Ahorn, Eberesche, Busch, Fichte und Tanne; ein Teil der Laubbäume ist schon herbstlich. Fichten und Tannen bestehen aus gemalten Zweigen. Wind bewegt Gras, Blätter und Zweige.
- **Landschaft:** Weg, Hügel und Bach sind Formeln (`scripts/land.gd`, für die Shader in `shaders/land.gdshaderinc`). Das Gelände entsteht in Kacheln rund um die aktuelle Position, in einem eigenen Thread (`scripts/world.gd`).
- **Texturen:** `tools/make_textures.py` malt Gras, Blätter und Zweige (Python mit Pillow).
- **Qualität:** Hoch, Mittel und Niedrig ändern die Dichte des Grases, die Sichtweite, die Schatten und die Auflösung. „Auto“ schaltet herunter, wenn weniger als 27 Bilder pro Sekunde gelingen.

## Bauen

Auf GitHub baut `.github/workflows/kvest-stilprobe.yml` die APK bei jeder Änderung in diesem Ordner.

Am Rechner reicht der Godot-Editor 4.7: Ordner öffnen und starten. Vorschaubilder ohne Editor:

```
godot --path . -- --capture <Ordner> --at 0,400,900 [--light abend] [--quality mittel]
godot --path . -- --capture <Ordner> --gallery sommer      (alle Baumarten nebeneinander, auch: herbst)
```
