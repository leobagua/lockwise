#!/usr/bin/env python3
"""Writes the animated SVGs used in the README.

Usage: assets/generate.py [freeze_seconds]
With freeze_seconds the animations stop at that instant, which is how the
frames are checked by eye.
"""
import sys
from pathlib import Path

LOOP_SECONDS = 12.0
SPAWN_EVERY = 0.35
LAST_SPAWN = 10.0
SPAWN_X = 30
GATE_X = 590
TABLE_X = 700
QUEUE_GAP = 24
SPEED = 350.0
GREEN = "#16a34a"
RED = "#dc2626"


def percent(seconds):
    return f"{max(0.0, min(seconds, LOOP_SECONDS)) / LOOP_SECONDS * 100:.3f}%"


def keyframes(name, steps):
    """steps is a list of (seconds, css declarations), in time order."""
    body = "".join(f"{percent(seconds)}{{{css}}}" for seconds, css in steps)
    return f"@keyframes {name}{{{body}}}"


def query_dots(pauses):
    """One dot per query. A dot that reaches the gate during a pause queues."""
    styles, shapes = [], []
    queued_in_pause = [0] * len(pauses)
    spawn = 0.2
    index = 0
    while spawn <= LAST_SPAWN:
        name = f"query{index}"
        steps = [(0, f"transform:translateX({SPAWN_X}px);opacity:0;fill:{GREEN}"),
                 (spawn, f"transform:translateX({SPAWN_X}px);opacity:0;fill:{GREEN}"),
                 (spawn + 0.05, f"transform:translateX({SPAWN_X}px);opacity:1;fill:{GREEN}")]
        pause_index = blocking_pause(spawn, pauses, queued_in_pause)
        if pause_index is None:
            entered = spawn + (TABLE_X - SPAWN_X) / SPEED
        else:
            position = queued_in_pause[pause_index]
            queued_in_pause[pause_index] += 1
            stop_x = GATE_X - position * QUEUE_GAP
            stopped = spawn + (stop_x - SPAWN_X) / SPEED
            released = pauses[pause_index][1] + position * 0.07
            entered = released + 0.4
            steps += [(stopped, f"transform:translateX({stop_x}px);opacity:1;fill:{GREEN}"),
                      (stopped + 0.15, f"transform:translateX({stop_x}px);opacity:1;fill:{RED}"),
                      (released, f"transform:translateX({stop_x}px);opacity:1;fill:{RED}")]
        steps += [(entered, f"transform:translateX({TABLE_X}px);opacity:1;fill:{GREEN}"),
                  (entered + 0.15, f"transform:translateX({TABLE_X}px);opacity:0;fill:{GREEN}"),
                  (LOOP_SECONDS, f"transform:translateX({TABLE_X}px);opacity:0;fill:{GREEN}")]
        styles.append(keyframes(name, steps))
        shapes.append(f'<circle class="moving" style="animation-name:{name}" cx="0" cy="170" r="9"/>')
        spawn += SPAWN_EVERY
        index += 1
    return styles, shapes


def blocking_pause(spawn, pauses, queued_in_pause):
    at_gate = spawn + (GATE_X - SPAWN_X) / SPEED
    for pause_index, (start, end) in enumerate(pauses):
        stop_x = GATE_X - queued_in_pause[pause_index] * QUEUE_GAP
        stopped = spawn + (stop_x - SPAWN_X) / SPEED
        if at_gate >= start and stopped < end:
            return pause_index
    return None


def visible_between(name, windows, hidden="opacity:0", shown="opacity:1"):
    steps = [(0, hidden)]
    for start, end in windows:
        steps += [(start, hidden), (start + 0.2, shown), (end, shown), (end + 0.2, hidden)]
    steps.append((LOOP_SECONDS, hidden))
    return keyframes(name, steps)


def captions(lines):
    styles, shapes = [], []
    for index, (start, end, text) in enumerate(lines):
        name = f"caption{index}"
        styles.append(visible_between(name, [(start, end - 0.2)]))
        shapes.append(f'<text class="moving caption" style="animation-name:{name}" x="450" y="46">{text}</text>')
    return styles, shapes


def document(styles, shapes, freeze):
    frozen = f"animation-delay:-{freeze}s;animation-play-state:paused;" if freeze is not None else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 290" font-family="Helvetica, Arial, sans-serif">
<style>
.moving{{animation-duration:{LOOP_SECONDS}s;animation-timing-function:linear;animation-iteration-count:infinite;{frozen}}}
.caption{{font-size:21px;font-weight:700;fill:#0f172a;text-anchor:middle}}
.label{{font-size:15px;fill:#475569;text-anchor:middle}}
.inside{{font-size:14px;font-weight:700;fill:#ffffff;text-anchor:middle}}
{"".join(styles)}
</style>
<rect width="900" height="290" rx="14" fill="#ffffff" stroke="#cbd5e1"/>
<line x1="30" y1="170" x2="640" y2="170" stroke="#e2e8f0" stroke-width="26" stroke-linecap="round"/>
<text class="label" x="70" y="212">queries</text>
<rect x="640" y="100" width="220" height="140" rx="12" fill="#f0fdf4" stroke="#15803d" stroke-width="2"/>
<text class="label" x="750" y="90">table</text>
{"".join(shapes)}
</svg>
"""


def long_transaction(end=None):
    name = "longtransaction"
    style = visible_between(name, [(0, end)]) if end else ""
    animation = f' class="moving" style="animation-name:{name}"' if end else ""
    shape = (f'<g{animation}><rect x="662" y="150" width="176" height="40" rx="8" fill="#1d4ed8"/>'
             '<text class="inside" x="750" y="175">long transaction</text></g>')
    return ([style] if style else []), [shape]


def ddl_block(name, label, steps):
    shape = (f'<g class="moving" style="animation-name:{name}">'
             '<rect x="596" y="142" width="40" height="56" rx="8" fill="#c2410c"/>'
             f'<text class="inside" x="616" y="130" style="fill:#c2410c">{label}</text></g>')
    return [keyframes(name, steps)], [shape]


def problem():
    pauses = [(2.0, 5.5), (7.0, 10.5)]
    away, at_gate = "transform:translateY(-48px);opacity:0", "transform:translateY(0);opacity:1"
    steps = [(0, away)]
    for start, end in pauses:
        steps += [(start - 0.3, away), (start, at_gate), (end, at_gate), (end + 0.3, away)]
    steps.append((LOOP_SECONDS, away))
    parts = [query_dots(pauses), long_transaction(), ddl_block("ddl", "DDL", steps), captions([
        (0.0, 2.0, "Queries run. A long transaction is open."),
        (2.0, 5.5, "The DDL waits for the lock. New queries queue behind it."),
        (5.5, 7.0, "Timeout. The DDL gives up."),
        (7.0, 10.5, "Retry. The table stops again."),
        (10.5, 12.0, "After many retries, the migration fails."),
    ])]
    return parts


def solution():
    pauses = [(7.2, 8.2)]
    away, waiting = "transform:translateY(-48px);opacity:0", "transform:translateY(-48px);opacity:1"
    at_gate = "transform:translateY(0);opacity:1"
    steps = [(0, away), (1.3, away), (1.6, waiting), (6.9, waiting), (7.2, at_gate),
             (8.2, at_gate), (8.5, away), (LOOP_SECONDS, away)]
    parts = [query_dots(pauses), long_transaction(end=6.5), ddl_block("lockwise", "lockwise", steps), captions([
        (0.0, 1.5, "Queries run. A long transaction is open."),
        (1.5, 6.6, "lockwise waits on a weak lock. Queries keep running."),
        (6.6, 8.3, "The transaction ends. lockwise asks for the strong lock once."),
        (8.3, 12.0, "DDL done after one short pause."),
    ])]
    return parts


def write(path, parts, freeze):
    styles = [style for part_styles, _ in parts for style in part_styles]
    shapes = [shape for _, part_shapes in parts for shape in part_shapes]
    path.write_text(document(styles, shapes, freeze))


def main():
    freeze = float(sys.argv[1]) if len(sys.argv) > 1 else None
    folder = Path(__file__).parent
    suffix = f"-{freeze}" if freeze is not None else ""
    write(folder / f"problem{suffix}.svg", problem(), freeze)
    write(folder / f"solution{suffix}.svg", solution(), freeze)


if __name__ == "__main__":
    main()
