# ~/.config/ramwidget/widget.py

import sys
import math
from PyQt6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QFrame, QSizePolicy
)
from PyQt6.QtGui import QPainter, QColor, QPen, QFont, QFontMetrics
from PyQt6.QtCore import Qt, QTimer, QRectF

from memdata import get_snapshot

# ── Pie chart widget ──────────────────────────────────────────
class PieChart(QWidget):
    def __init__(self):
        super().__init__()
        self.setFixedSize(110, 110)
        self.slices = []
        self.center_text = ("0", "MB USED")

    def set_data(self, slices, center_text):
        self.slices = slices       # list of (fraction, QColor)
        self.center_text = center_text
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)

        cx, cy = self.width() / 2, self.height() / 2
        r = min(cx, cy) - 4
        rect = QRectF(cx - r, cy - r, r * 2, r * 2)

        angle = 90 * 16
        total_units = 360 * 16
        used_units = 0
        for i, (frac, color) in enumerate(self.slices):
            if i < len(self.slices) - 1:
                span = int(frac * total_units)
            else:
                span = total_units - used_units  # last slice fills remainder exactly
            if span <= 0:
                continue
            p.setBrush(color)
            p.setPen(Qt.PenStyle.NoPen)
            p.drawPie(rect, angle, -span)
            angle -= span
            used_units += span

        # Donut hole
        hole_r = r * 0.58
        p.setBrush(QColor("#0d1117"))
        p.setPen(Qt.PenStyle.NoPen)
        p.drawEllipse(QRectF(cx - hole_r, cy - hole_r, hole_r * 2, hole_r * 2))

        # Center text
        val, lbl = self.center_text
        p.setPen(QColor("#e6edf3"))
        f = QFont("JetBrains Mono", 13, QFont.Weight.Medium)
        p.setFont(f)
        fm = QFontMetrics(f)
        p.drawText(
            QRectF(cx - 40, cy - 16, 80, 20),
            Qt.AlignmentFlag.AlignCenter, val
        )
        p.setPen(QColor("#8b949e"))
        f2 = QFont("JetBrains Mono", 7)
        p.setFont(f2)
        p.drawText(
            QRectF(cx - 40, cy + 3, 80, 14),
            Qt.AlignmentFlag.AlignCenter, lbl
        )
        p.end()


# ── Process bar row ───────────────────────────────────────────
class ProcRow(QWidget):
    def __init__(self, name, mb, color, is_other=False):
        super().__init__()
        self.name_lbl = QLabel(name)
        self.bar_widget = QWidget()
        self.bar_widget.setFixedHeight(4)
        self.bar_inner = QWidget(self.bar_widget)
        self.bar_inner.setFixedHeight(4)
        self.mb_lbl = QLabel(f"{mb} MB")

        alpha = 0.5 if is_other else 1.0
        c = QColor(color)
        c.setAlphaF(alpha)

        name_color = "#484f58" if is_other else "#c9d1d9"
        mb_color   = "#484f58" if is_other else "#8b949e"

        self.name_lbl.setStyleSheet(f"color:{name_color}; font-size:11px;")
        self.mb_lbl.setStyleSheet(f"color:{mb_color}; font-size:11px;")
        self.bar_widget.setStyleSheet("background:#21262d; border-radius:2px;")
        self.bar_inner.setStyleSheet(
            f"background:{color}; border-radius:2px; opacity:{alpha};"
        )

        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)
        self.name_lbl.setFixedWidth(90)
        self.mb_lbl.setFixedWidth(50)
        self.mb_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.bar_widget.setFixedWidth(76)
        layout.addWidget(self.name_lbl)
        layout.addWidget(self.bar_widget)
        layout.addWidget(self.mb_lbl)       
        self._mb = mb
        self._color = color

    def set_bar_fraction(self, frac):
        w = max(2, int(frac * 80))
        self.bar_inner.setGeometry(0, 0, w, 4)


# ── Main window ───────────────────────────────────────────────
class RamWidget(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("RAM")
        self.setFixedWidth(300)
        # Frameless floating window
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint |
            Qt.WindowType.WindowStaysOnTopHint |
            Qt.WindowType.Tool
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_NoSystemBackground)

        # Root container with dark bg
        self.container = QFrame(self)
        self.container.setObjectName("container")
        self.container.setStyleSheet("""
            QFrame#container {
                background: #0d1117;
                border: 0.5px solid #30363d;
                border-radius: 12px;
            }
        """)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.addWidget(self.container)

        inner = QVBoxLayout(self.container)
        inner.setContentsMargins(16, 14, 16, 14)
        inner.setSpacing(0)

        # ── Title row
        title_row = QHBoxLayout()
        title = QLabel("MEMORY")
        title.setStyleSheet("color:#8b949e; font-size:10px; letter-spacing:1px;")
        self.pct_lbl = QLabel("0%")
        self.pct_lbl.setStyleSheet("color:#f4a15d; font-size:13px; font-weight:500;")
        title_row.addWidget(title)
        title_row.addStretch()
        title_row.addWidget(self.pct_lbl)
        inner.addLayout(title_row)
        inner.addSpacing(12)

        # ── Pie + stats row
        pie_row = QHBoxLayout()
        pie_row.setSpacing(14)
        self.pie = PieChart()
        pie_row.addWidget(self.pie)

        stats_col = QVBoxLayout()
        stats_col.setSpacing(7)
        self.stat_used  = self._stat_row("Used",  "#f4a15d")
        self.stat_free  = self._stat_row("Free",  "#484f58")
        self.stat_total = self._stat_row("Total", "#8b949e")
        stats_col.addLayout(self.stat_used[0])
        stats_col.addLayout(self.stat_free[0])
        stats_col.addLayout(self.stat_total[0])
        stats_col.addStretch()
        pie_row.addLayout(stats_col)
        inner.addLayout(pie_row)
        inner.addSpacing(12)

        # ── Divider
        div = QFrame()
        div.setFrameShape(QFrame.Shape.HLine)
        div.setStyleSheet("border: none; border-top: 0.5px solid #21262d; margin:0;")
        inner.addWidget(div)
        inner.addSpacing(10)

        # ── Process list (placeholder, built on first update)
        self.proc_layout = QVBoxLayout()
        self.proc_layout.setSpacing(7)
        self.proc_rows: list[ProcRow] = []
        inner.addLayout(self.proc_layout)

        # ── Timer
        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(2000)
        self.refresh()

    def _stat_row(self, label, dot_color):
        row = QHBoxLayout()
        row.setSpacing(6)
        dot = QLabel("●")
        dot.setStyleSheet(f"color:{dot_color}; font-size:9px;")
        lbl = QLabel(label)
        lbl.setStyleSheet("color:#8b949e; font-size:11px;")
        val = QLabel("—")
        val.setStyleSheet("color:#e6edf3; font-size:12px; font-weight:500;")
        row.addWidget(dot)
        row.addWidget(lbl)
        row.addStretch()
        row.addWidget(val)
        return row, val

    def refresh(self):
        snap = get_snapshot()
        s    = snap["system"]
        procs = snap["processes"]

        # Header
        self.pct_lbl.setText(f"{s['used_pct']}%")
        self.stat_used[1].setText(f"{s['used_mb']} MB")
        self.stat_free[1].setText(f"{s['free_mb']} MB")
        self.stat_total[1].setText(f"{s['total_mb']} MB")

        # Pie slices
        free_frac = s["free_mb"] / s["total_mb"]
        slices = [(p["kb"] / (s["total_mb"] * 1024), QColor(p["color"])) for p in procs]
        slices.append((free_frac, QColor("#21262d")))
        self.pie.set_data(slices, (str(s["used_mb"]), "MB USED"))

        # Rebuild process rows if count changed
        if len(procs) != len(self.proc_rows):
            for w in self.proc_rows:
                self.proc_layout.removeWidget(w)
                w.deleteLater()
            self.proc_rows = []
            for p in procs:
                row = ProcRow(p["name"], p["mb"], p["color"], p.get("is_other", False))
                self.proc_layout.addWidget(row)
                self.proc_rows.append(row)

        # Update existing rows
        max_mb = procs[0]["mb"] if procs else 1
        for row, p in zip(self.proc_rows, procs):
            row.name_lbl.setText(p["name"])
            row.mb_lbl.setText(f"{p['mb']} MB")
            row.set_bar_fraction(p["mb"] / max_mb)

        self.adjustSize()


if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setFont(QFont("JetBrains Mono", 10))
    w = RamWidget()
    w.move(1600, 20)   # adjust to your screen position
    w.show()
    sys.exit(app.exec())
