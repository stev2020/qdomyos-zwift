# Kvest Stilprobe

Eine Probe für den Look der Welt von Kvest, gebaut mit [Godot](https://godotengine.org) 4.7. Vorbild ist der Stil von Wilderless: Meadowfell. Die Probe zeigt einen endlosen Weg durch die vier Landschaften von Kvest: Laubland, Heide, Flusstal und Hochland, bei Sommertag oder Abendsonne.

Die Probe ist eine eigene App (`io.github.stev2020.kveststilprobe`) und läuft neben Kvestrun. Das Tempo holt sie sich von Kvestrun auf demselben Tablet. Dafür verbindet sie sich mit dem eingebauten Webserver von Kvestrun (Port 6680) oder QZ (Port 6666), der jede Sekunde die Werte der Fahrt schickt. Ohne Kvestrun fährt sie im Demo-Tempo, das man unten links einstellt.

APK: https://github.com/stev2020/qdomyos-zwift/releases/download/kvest-stilprobe/kvest-stilprobe.apk

## Die Knöpfe

- **Qualität:** Auto, Hoch, Mittel, Niedrig. Sie ändern die Dichte des Grases, die Sichtweite, die Schatten und die Auflösung. „Auto“ schaltet herunter, wenn weniger als 27 Bilder pro Sekunde gelingen.
- **Licht:** Sommertag oder Abendsonne.
- **Landschaft:** „Wechsel“ fährt durch alle Landschaften, jede 4 km lang: Laubland, Heide, Laubland, Flusstal, Hochland, Flusstal. Oder eine Landschaft bleibt fest. Nach dem Umschalten wird die Welt neu aufgebaut.

## Die Landschaften

| Landschaft | Boden und Weg | Pflanzen | Wasser | Höhen |
|---|---|---|---|---|
| Laubland | dunkle Erde, Feldweg | Buche, Eiche, Ahorn, Büsche, Blumenwiesen | Bach | wellig |
| Heide | heller Sand, Sandweg | Heidekraut, Kiefer, Birke, Wacholder, Borstgras, Findlinge | keins | fast eben |
| Flusstal | Kies, Schotterweg | Fichte und Tanne am Hang, Weiden am Fluss, Ebereschen | Fluss mit Kiesbänken | eben, Hänge zu beiden Seiten |
| Hochland | Fels und Geröll, steiniger Saumpfad | Latschen, kleine Ebereschen, Borstgras, Felsen | Gebirgsbach | lange Anstiege |

Die Übergänge sind weich: Das Aussehen wechselt über 600 m, die Höhen über 1,8 km.

## So ist sie gebaut

- **Landschaften:** `scripts/land.gd` beschreibt Weg, Bach und die vier Landschaften als Formeln: ihren Anteil an jeder Stelle, die Höhen, die Breite des Wassers und den kahlen Boden (Sand, Geröll). Für die Shader steht der Weg in `shaders/land.gdshaderinc`.
- **Gelände:** `scripts/world.gd` baut Gelände, Gras, Bäume und Wasser in Kacheln, in einem eigenen Thread. Die Anteile der Landschaften stecken in den Farben der Gelände-Punkte, und `shaders/terrain.gdshader` mischt damit Boden-, Weg- und Bachfarben (Farben in `GROUND` in `scripts/main.gd`).
- **Gras:** Büschel aus sechs sich kreuzenden Flächen (12 Dreiecke) mit gemalten Halmen. Acht Sorten: üppig, mit Samen, kurz, mit Blüten, mit lila Rispen, Schilf, Heidekraut und Borstgras.
- **Bäume und Büsche:** Blätterbüschel aus drei sich kreuzenden Flächen mit gemalten Blättern und deren Normalen. Arten: Buche, Birke, Eiche, Ahorn, Eberesche, Busch, Weide, Fichte, Tanne, Kiefer, Wacholder und Latsche; ein Teil der Laubbäume ist schon herbstlich. Stämme und Äste sind aus flachen Flächen geschnitzt. Wind bewegt Gras, Blätter und Zweige.
- **Felsen:** runde, bemooste Steine und kantige, graue Felsen aus flachen Flächen.
- **Texturen:** `tools/make_textures.py` malt Gras, Blätter, Nadeln und Zweige (Python mit Pillow).

## Bauen

Auf GitHub baut `.github/workflows/kvest-stilprobe.yml` die APK bei jeder Änderung in diesem Ordner.

Am Rechner reicht der Godot-Editor 4.7: Ordner öffnen und starten. Vorschaubilder ohne Editor:

```
godot --path . -- --capture <Ordner> --at 0,400,900 [--light abend] [--quality mittel] [--land laub|heide|fluss|hoch]
godot --path . -- --capture <Ordner> --gallery sommer      (alle Pflanzen nebeneinander, auch: herbst)
godot --headless --path . -s res://tools/steigungen.gd     (Steigungen je Landschaft)
```
