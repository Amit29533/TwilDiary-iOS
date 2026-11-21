"""ASS subtitles for the performance video: a styled line every three seconds for two minutes, two
lines at a time half the time, as an anime release has them (styles with outline and shadow)."""
HEADER = """[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,2,2,120,120,60,1
Style: Sign,Arial,52,&H0000E0FF,&H000000FF,&H00202020,&H80000000,1,0,0,0,100,100,0,0,1,2,0,8,60,60,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


def stamp(seconds):
    return "%d:%02d:%02d.%02d" % (seconds // 3600, seconds // 60 % 60, seconds % 60, 0)


lines = [HEADER]
for n, start in enumerate(range(0, 120, 3)):
    text = "Line %d of the performance run" % (n + 1)
    if n % 2:
        text += r"\N{\i1}and a second line under it{\i0}"
    lines.append("Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n" % (stamp(start), stamp(start + 2), text))
    if n % 5 == 0:
        lines.append("Dialogue: 0,%s,%s,Sign,,0,0,0,,{\\pos(960,120)}A sign at the top\n" % (stamp(start), stamp(start + 3)))
print("".join(lines), end="")
