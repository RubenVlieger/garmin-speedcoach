/**
 * AxisCalibrator.mc
 * ─────────────────────────────────────────────────────────────────────────────
 * Automatic, user-transparent orientation detection for the Pro Rowing app.
 *
 * PHASE MACHINE:
 *
 *  PHASE_GRAVITY (2 s, hold still)
 *    → averages raw accel to find [gx, gy, gz] gravity vector
 *
 *  PHASE_LEARNING (first 3 strokes)
 *    → gravity-compensates each sample
 *    → scores all 3 axes by peak-to-peak amplitude
 *    → highest amplitude axis = forward axis
 *    → sign determined from which peak is larger (drive is always a positive spike)
 *
 *  PHASE_LOCKED (normal racing)
 *    → outputs gravity-compensated forward accel
 *    → slow EMA (α=0.001) continuously corrects gravity during quiet glide moments
 *    → monitors lateral axes for sustained spikes (knock detection)
 *
 *  PHASE_RECALIBRATE (after knock)
 *    → 1.5 s g
 ravity re-sample, then re-learning
 *    → shows amber arc on UI so rower knows something changed
 */

using Toybox.System as System;
import Toybox.Lang;

class AxisCalibrator {

    // ─── Phase Constants (public so View can read them) ───────────────────────
    static const PHASE_GRAVITY     = 0;
    static const PHASE_LEARNING    = 1;
    static const PHASE_LOCKED      = 2;
    static const PHASE_RECALIBRATE = 3;

    // ─── Tuning ───────────────────────────────────────────────────────────────
    private const GRAVITY_SAMPLES_NEEDED  = 50;   // 2 s at 25 Hz
    private const RECAL_SAMPLES_NEEDED    = 38;   // 1.5 s at 25 Hz
    private const LEARNING_STROKES_NEEDED = 3;

    // Gravity adaptation — only during quiet glide moments between strokes.
    // α=0.001 → τ ≈ 40 s.  Corrects gentle knocks silently over ~2 minutes.
    private const GRAVITY_ADAPT_ALPHA  = 0.001f;
    private const QUIET_THRESHOLD_MS2  = 0.30f;   // m/s² — below this = "quiet"

    // Knock detection: lateral gravity-compensated RMS must exceed this for
    // KNOCK_CONFIRM_SAMPLES consecutive samples to trigger recalibration.
    private const KNOCK_THRESHOLD_MS2   = 2.5f;
    private const KNOCK_CONFIRM_SAMPLES = 8;      // ~320 ms at 25 Hz

    private const MG_TO_MS2 = 0.00981f;

    // ─── Public State ─────────────────────────────────────────────────────────
    var phase       as Number;
    var forwardAxis as Number;   // 0=X, 1=Y, 2=Z  (valid after PHASE_LOCKED)
    var forwardSign as Float;    // +1.0 or -1.0

    // ─── Private State ────────────────────────────────────────────────────────
    private var _grav       as Array;    // [gx, gy, gz] in m/s²
    private var _gravAccum  as Array;    // accumulator during sampling phases
    private var _gravCount  as Number;

    private var _axisMax    as Array;    // per-axis peak positive linear accel
    private var _axisMin    as Array;    // per-axis peak negative linear accel
    private var _learningStrokeCount as Number;

    private var _knockCounter as Number;

    // ─────────────────────────────────────────────────────────────────────────
    function initialize() {
        phase       = PHASE_GRAVITY;
        forwardAxis = 0;
        forwardSign = 1.0f;

        _grav      = [0.0f, 0.0f, 0.0f];
        _gravAccum = [0.0f, 0.0f, 0.0f];
        _gravCount = 0;

        _axisMax = [-999.0f, -999.0f, -999.0f];
        _axisMin = [ 999.0f,  999.0f,  999.0f];
        _learningStrokeCount = 0;

        _knockCounter = 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC API
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * processSample
     * Call once per raw accel sample (25 Hz).
     * Returns a CalibResult with the gravity-compensated forward accel (m/s²)
     * and an isReady flag (false during calibration phases → suppress pace display).
     *
     * @param rawMg_x  raw X in milli-g
     * @param rawMg_y  raw Y in milli-g
     * @param rawMg_z  raw Z in milli-g
     */
    function processSample(rawMg_x as Number, rawMg_y as Number, rawMg_z as Number) as CalibResult {
        var ax = rawMg_x * MG_TO_MS2;
        var ay = rawMg_y * MG_TO_MS2;
        var az = rawMg_z * MG_TO_MS2;

        if (phase == PHASE_GRAVITY || phase == PHASE_RECALIBRATE) {
            return _handleGravityPhase(ax, ay, az);
        }
        if (phase == PHASE_LEARNING) {
            return _handleLearningPhase(ax, ay, az);
        }
        if (phase == PHASE_LOCKED) {
            return _handleLockedPhase(ax, ay, az);
        }
        return new CalibResult(0.0f, false);
    }

    /**
     * notifyStrokeDetected
     * Called by StrokeProcessor when a catch is confirmed.
     * Advances the PHASE_LEARNING stroke counter — once 3 strokes are seen,
     * the best axis is committed and we transition to PHASE_LOCKED.
     */
    function notifyStrokeDetected() as Void {
        if (phase != PHASE_LEARNING) {
            return;
        }
        _learningStrokeCount++;
        if (_learningStrokeCount >= LEARNING_STROKES_NEEDED) {
            _lockAxis();
        }
    }

    /**
     * triggerRecalibration
     * Externally callable — fires on user tap or can be called programmatically.
     * Resets the calibrator to PHASE_RECALIBRATE without losing strokeCount or
     * pace history (those live in StrokeProcessor).
     */
    function triggerRecalibration() as Void {
        phase        = PHASE_RECALIBRATE;
        _gravAccum   = [0.0f, 0.0f, 0.0f];
        _gravCount   = 0;
        _axisMax     = [-999.0f, -999.0f, -999.0f];
        _axisMin     = [ 999.0f,  999.0f,  999.0f];
        _learningStrokeCount = 0;
        _knockCounter = 0;
    }

    /**
     * isReady — true only when PHASE_LOCKED.
     */
    function isReady() as Boolean {
        return phase == PHASE_LOCKED;
    }

    /**
     * getStatusString — human-readable phase label for the calibration screen.
     */
    function getStatusString() as String {
        if (phase == PHASE_GRAVITY)     { return "Hold still..."; }
        if (phase == PHASE_LEARNING)    { return "Row 3 strokes..."; }
        if (phase == PHASE_RECALIBRATE) { return "Re-calibrating..."; }
        return "";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: PHASE HANDLERS
    // ─────────────────────────────────────────────────────────────────────────

    private function _handleGravityPhase(ax as Float, ay as Float, az as Float) as CalibResult {
        _gravAccum[0] = _gravAccum[0] + ax;
        _gravAccum[1] = _gravAccum[1] + ay;
        _gravAccum[2] = _gravAccum[2] + az;
        _gravCount++;

        var needed = (phase == PHASE_RECALIBRATE) ? RECAL_SAMPLES_NEEDED : GRAVITY_SAMPLES_NEEDED;

        if (_gravCount >= needed) {
            var n = _gravCount.toFloat();
            _grav[0] = _gravAccum[0] / n;
            _grav[1] = _gravAccum[1] / n;
            _grav[2] = _gravAccum[2] / n;
            phase = PHASE_LEARNING;
        }

        return new CalibResult(0.0f, false);
    }

    private function _handleLearningPhase(ax as Float, ay as Float, az as Float) as CalibResult {
        // Subtract gravity to get linear (motion-only) acceleration
        var lx = ax - (_grav[0] as Float);
        var ly = ay - (_grav[1] as Float);
        var lz = az - (_grav[2] as Float);

        // Update per-axis amplitude trackers
        if (lx > (_axisMax[0] as Float)) { _axisMax[0] = lx; }
        if (ly > (_axisMax[1] as Float)) { _axisMax[1] = ly; }
        if (lz > (_axisMax[2] as Float)) { _axisMax[2] = lz; }
        if (lx < (_axisMin[0] as Float)) { _axisMin[0] = lx; }
        if (ly < (_axisMin[1] as Float)) { _axisMin[1] = ly; }
        if (lz < (_axisMin[2] as Float)) { _axisMin[2] = lz; }

        // Find best axis so far for a tentative return value
        var pp0 = (_axisMax[0] as Float) - (_axisMin[0] as Float);
        var pp1 = (_axisMax[1] as Float) - (_axisMin[1] as Float);
        var pp2 = (_axisMax[2] as Float) - (_axisMin[2] as Float);

        var tentative = lx;
        if (pp1 > pp0 && pp1 >= pp2) { tentative = ly; }
        if (pp2 > pp0 && pp2 > pp1)  { tentative = lz; }

        // Return tentative value with isReady=false so pace is suppressed
        // but the state machine still sees strokes and can call notifyStrokeDetected()
        return new CalibResult(tentative, false);
    }

    private function _lockAxis() as Void {
        var pp0 = (_axisMax[0] as Float) - (_axisMin[0] as Float);
        var pp1 = (_axisMax[1] as Float) - (_axisMin[1] as Float);
        var pp2 = (_axisMax[2] as Float) - (_axisMin[2] as Float);

        forwardAxis = 0;
        var bestPP  = pp0;
        if (pp1 > bestPP) { bestPP = pp1; forwardAxis = 1; }
        if (pp2 > bestPP) { bestPP = pp2; forwardAxis = 2; }

        // Sign: drive produces a larger positive peak than recovery negative peak
        var axMax = _axisMax[forwardAxis] as Float;
        var axMin = _axisMin[forwardAxis] as Float;
        forwardSign = (axMax >= -axMin) ? 1.0f : -1.0f;

        phase = PHASE_LOCKED;
        _knockCounter = 0;

        System.println("AxisCalibrator LOCKED → axis=" + forwardAxis + " sign=" + forwardSign);
    }

    private function _handleLockedPhase(ax as Float, ay as Float, az as Float) as CalibResult {
        // ── Gravity-compensated linear accelerations ───────────────────────
        var lx = ax - (_grav[0] as Float);
        var ly = ay - (_grav[1] as Float);
        var lz = az - (_grav[2] as Float);

        // ── Extract forward component with auto-detected sign ──────────────
        var forwardLinear = 0.0f;
        if (forwardAxis == 0)      { forwardLinear = forwardSign * lx; }
        else if (forwardAxis == 1) { forwardLinear = forwardSign * ly; }
        else                       { forwardLinear = forwardSign * lz; }

        // ── Slow gravity adaptation — quiet moments only ───────────────────
        // Only run during near-zero forward accel (glide between strokes).
        // This silently corrects slow orientation drift over ~2 minutes.
        if (forwardLinear < QUIET_THRESHOLD_MS2 && forwardLinear > -QUIET_THRESHOLD_MS2) {
            var beta = 1.0f - GRAVITY_ADAPT_ALPHA;
            _grav[0] = beta * (_grav[0] as Float) + GRAVITY_ADAPT_ALPHA * ax;
            _grav[1] = beta * (_grav[1] as Float) + GRAVITY_ADAPT_ALPHA * ay;
            _grav[2] = beta * (_grav[2] as Float) + GRAVITY_ADAPT_ALPHA * az;
        }

        // ── Knock detection ────────────────────────────────────────────────
        _detectKnock(lx, ly, lz);

        return new CalibResult(forwardLinear, true);
    }

    private function _detectKnock(lx as Float, ly as Float, lz as Float) as Void {
        // Compute RMS energy on the two non-forward lateral axes
        var lat1 = 0.0f;
        var lat2 = 0.0f;

        if (forwardAxis == 0)      { lat1 = ly; lat2 = lz; }
        else if (forwardAxis == 1) { lat1 = lx; lat2 = lz; }
        else                       { lat1 = lx; lat2 = ly; }

        var lateralEnergy = Math.sqrt(lat1 * lat1 + lat2 * lat2).toFloat();

        if (lateralEnergy > KNOCK_THRESHOLD_MS2) {
            _knockCounter++;
        } else {
            if (_knockCounter > 0) { _knockCounter--; }
        }

        if (_knockCounter >= KNOCK_CONFIRM_SAMPLES) {
            System.println("AxisCalibrator: knock detected, recalibrating...");
            triggerRecalibration();
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VALUE OBJECT returned by processSample()
// ─────────────────────────────────────────────────────────────────────────────

class CalibResult {
    var linearForwardMs2 as Float;
    var isReady          as Boolean;

    function initialize(val as Float, ready as Boolean) {
        linearForwardMs2 = val;
        isReady          = ready;
    }
}
