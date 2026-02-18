/**
 * RowingView.mc  (v2 — calibration-aware)
 * ─────────────────────────────────────────────────────────────────────────────
 * Renders two distinct screens:
 *
 *  CALIBRATION SCREEN — shown while AxisCalibrator is not yet locked.
 *    Displays a phase label, animated progress arc, and simple instructions.
 *    User instruction: "Hold still" then "Row 3 strokes" — no jargon.
 *
 *  RACING SCREEN — shown once calibrator is PHASE_LOCKED.
 *    Primary:   pace /500m in large amber digits
 *    Secondary: speed (m/s) | stroke rate (spm)
 *    Footer:    stroke count, state label, GPS indicator, pause flag
 */

using Toybox.WatchUi  as WatchUi;
using Toybox.Graphics as Gfx;
using Toybox.System   as System;
using Toybox.Math     as Math;
import Toybox.Lang;

class speedcoachView extends WatchUi.View {

    // Colour palette
    private const COLOR_BG        = Gfx.COLOR_BLACK;
    private const COLOR_PACE      = 0xFFAA00;
    private const COLOR_SECONDARY = 0xCCCCCC;
    private const COLOR_LABEL     = 0x888888;
    private const COLOR_ACCENT    = 0x00AAFF;
    private const COLOR_DRV       = 0x00CC66;
    private const COLOR_REC       = 0x4488FF;
    private const COLOR_IDL       = 0x555555;
    private const COLOR_GPS_OK    = 0x00CC66;
    private const COLOR_GPS_LOST  = 0xCC4444;
    private const COLOR_PAUSED    = 0xCC4444;
    private const COLOR_WHITE     = 0xFFFFFF;
    private const COLOR_RECAL     = 0xFF6600;   // amber for recalibration arc
    private const COLOR_HR = 0xFF5555;

    private var _proc as StrokeProcessor;

    // Layout cache
    private var _w  as Number;
    private var _h  as Number;
    private var _cx as Number;
    private var _cy as Number;
    private var _r  as Number;

    function initialize(processor as StrokeProcessor) {
        View.initialize();
        _proc = processor;
        _w = 260; _h = 260; _cx = 130; _cy = 130; _r = 130;
    }

    function onLayout(dc as Gfx.Dc) as Void {
        _w  = dc.getWidth();
        _h  = dc.getHeight();
        _cx = _w / 2;
        _cy = _h / 2;
        _r  = (_w < _h ? _w : _h) / 2;
    }

    function onShow()  as Void {}
    function onHide()  as Void {}

    function onUpdate(dc as Gfx.Dc) as Void {
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();

        if (_proc.calibrator.isReady()) {
            _drawRacingScreen(dc);
        } else {
            _drawCalibrationScreen(dc);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CALIBRATION SCREEN
    // ─────────────────────────────────────────────────────────────────────────

    private function _drawCalibrationScreen(dc as Gfx.Dc) as Void {
        var phase = _proc.calibrator.phase;

        // App name
        dc.setColor(COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx, _sy(0.18f), Gfx.FONT_SMALL, "speedcoach", Gfx.TEXT_JUSTIFY_CENTER);

        // Phase label
        var statusStr = _proc.calibrator.getStatusString();
        dc.setColor(COLOR_ACCENT, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx, _sy(0.36f), Gfx.FONT_SMALL, statusStr, Gfx.TEXT_JUSTIFY_CENTER);

        // Progress arc
        _drawCalibProgress(dc, phase);

        // Instruction text
        dc.setColor(COLOR_LABEL, Gfx.COLOR_TRANSPARENT);
        if (phase == AxisCalibrator.PHASE_LEARNING) {
            dc.drawText(_cx, _sy(0.72f), Gfx.FONT_XTINY, "Row 3 full strokes", Gfx.TEXT_JUSTIFY_CENTER);
            dc.drawText(_cx, _sy(0.80f), Gfx.FONT_XTINY, "to calibrate", Gfx.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(_cx, _sy(0.72f), Gfx.FONT_XTINY, "Hold watch still", Gfx.TEXT_JUSTIFY_CENTER);
            dc.drawText(_cx, _sy(0.80f), Gfx.FONT_XTINY, "on the rigger", Gfx.TEXT_JUSTIFY_CENTER);
        }
    }

    private function _drawCalibProgress(dc as Gfx.Dc, phase as Number) as Void {
        var arcRadius = _r - 28;

        // Background ring
        dc.setColor(0x333333, Gfx.COLOR_TRANSPARENT);
        dc.setPenWidth(6);
        dc.drawArc(_cx, _cy, arcRadius, Gfx.ARC_CLOCKWISE, 90, 90 - 270);

        if (phase == AxisCalibrator.PHASE_LEARNING) {
            // Three dots — one lights up per confirmed stroke
            var confirmed = _proc.strokeCount;
            if (confirmed > 3) { confirmed = 3; }

            for (var i = 0; i < 3; i++) {
                // Place dots at 210°, 270°, 330°
                var angleDeg = 210 + i * 60;
                var angleRad = angleDeg * Math.PI / 180.0f;
                var dotX = (_cx + arcRadius * Math.cos(angleRad) + 0.5f).toNumber();
                var dotY = (_cy - arcRadius * Math.sin(angleRad) + 0.5f).toNumber();

                var dotColor = (i < confirmed) ? COLOR_ACCENT : 0x333333;
                dc.setColor(dotColor, Gfx.COLOR_TRANSPARENT);
                dc.fillCircle(dotX, dotY, 8);
            }
        } else {
            // Animated sweep arc for gravity phase
            var arcColor = (phase == AxisCalibrator.PHASE_RECALIBRATE) ? COLOR_RECAL : COLOR_ACCENT;
            var elapsed  = System.getTimer() % 2200;
            var sweep    = (elapsed.toFloat() / 2200.0f * 270.0f).toNumber();

            dc.setColor(arcColor, Gfx.COLOR_TRANSPARENT);
            dc.setPenWidth(6);
            dc.drawArc(_cx, _cy, arcRadius, Gfx.ARC_CLOCKWISE, 90, 90 - sweep);
        }

        dc.setPenWidth(1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RACING SCREEN
    // ─────────────────────────────────────────────────────────────────────────

    private function _drawRacingScreen(dc as Gfx.Dc) as Void {
        var paceStr   = _proc.getPaceString();
        var speedMs   = _proc.currentSpeedMs;
        var spm       = _proc.strokeRateSpm;
        var count     = _proc.strokeCount;
        var paused    = _proc.isPaused;
        var stateLbl  = _proc.getStateLabel();
        var paceColor = paused ? COLOR_PAUSED : COLOR_PACE;

        // Unit label
        dc.setColor(COLOR_LABEL, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx, _sy(0.20f), Gfx.FONT_XTINY, "/500m", Gfx.TEXT_JUSTIFY_CENTER);

        // Primary pace
        dc.setColor(paceColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx, _sy(0.34f), Gfx.FONT_NUMBER_HOT, paceStr, Gfx.TEXT_JUSTIFY_CENTER);

        // Secondary row: speed | spm
        var y2 = _sy(0.61f);
        dc.setColor(COLOR_SECONDARY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_sx(0.28f), y2, Gfx.FONT_SMALL,
                    speedMs.format("%.1f") + " m/s", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(COLOR_LABEL, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx, y2, Gfx.FONT_SMALL, "|", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(COLOR_SECONDARY, Gfx.COLOR_TRANSPARENT);
        var spmStr = (spm != null) ? spm.format("%d") + " spm" : "-- spm";
        dc.drawText(_sx(0.73f), y2, Gfx.FONT_SMALL, spmStr, Gfx.TEXT_JUSTIFY_CENTER);

        // Stroke count + state label
        var y3 = _sy(0.75f);
        dc.setColor(COLOR_SECONDARY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_sx(0.28f), y3, Gfx.FONT_TINY,
                    "Str: " + count.format("%d"), Gfx.TEXT_JUSTIFY_CENTER);

        var stateColor = COLOR_IDL;
        if (stateLbl.equals("DRV")) { stateColor = COLOR_DRV; }
        if (stateLbl.equals("REC")) { stateColor = COLOR_REC; }
        dc.setColor(stateColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_sx(0.73f), y3, Gfx.FONT_TINY, stateLbl, Gfx.TEXT_JUSTIFY_CENTER);

        // Status bar: GPS dot + PAUSE
        var y4 = _sy(0.88f);
        var gpsColor = (_proc.currentSpeedMs > 0.05f) ? COLOR_GPS_OK : COLOR_GPS_LOST;
        dc.setColor(gpsColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx - 28, y4, Gfx.FONT_XTINY, "●", Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(COLOR_LABEL, Gfx.COLOR_TRANSPARENT);
        dc.drawText(_cx - 14, y4, Gfx.FONT_XTINY, "GPS", Gfx.TEXT_JUSTIFY_LEFT);

        if (_proc.currentHr != null) {
            dc.setColor(COLOR_HR, Gfx.COLOR_TRANSPARENT);
            dc.drawText(_cx + 22, y4, Gfx.FONT_XTINY, _proc.currentHr.format("%d") + " bpm", Gfx.TEXT_JUSTIFY_LEFT);
        } else {
            dc.setColor(COLOR_LABEL, Gfx.COLOR_TRANSPARENT);
            dc.drawText(_cx + 22, y4, Gfx.FONT_XTINY, "-- bpm", Gfx.TEXT_JUSTIFY_LEFT);
        }

        if (paused) {
            dc.setColor(COLOR_PAUSED, Gfx.COLOR_TRANSPARENT);
            dc.drawText(_cx + 22, y4, Gfx.FONT_XTINY, "PAUSE", Gfx.TEXT_JUSTIFY_LEFT);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    // Proportional coordinates — keeps layout resolution-independent
    private function _sy(f as Float) as Number { return (_h.toFloat() * f + 0.5f).toNumber(); }
    private function _sx(f as Float) as Number { return (_w.toFloat() * f + 0.5f).toNumber(); }
}
