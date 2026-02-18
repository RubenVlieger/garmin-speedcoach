/**
 * StrokeProcessor.mc  (v2 — calibrator-driven)
 * ─────────────────────────────────────────────────────────────────────────────
 * Physics engine for the Pro Rowing app.
 *
 * Receives gravity-compensated forward accel (m/s²) from AxisCalibrator,
 * runs: LPF → Complementary Filter (GPS) → Trapezoidal integrator
 *        → State Machine → Pace calculator
 *
 * NOTE ON MONKEY C LOCAL VARIABLES:
 *   Local variables are always type-inferred.  Never write "var x as Number;"
 *   for a local — that syntax is only valid for class fields and parameters.
 *   All locals here use initialised declarations: "var x = 0;" or "var x = 0.0f;"
 */

using Toybox.System as System;
import Toybox.Lang;
import Toybox.Sensor;

class StrokeProcessor {

    // ─── Signal Processing ────────────────────────────────────────────────────
    private const LPF_ALPHA = 0.15f;   // Low-pass filter: ~0.65 Hz cutoff at 25 Hz
    private const CF_ALPHA  = 0.98f;   // Complementary filter: 98% inertial, 2% GPS

    // ─── State Machine ────────────────────────────────────────────────────────
    private const STATE_IDLE     = 0;
    private const STATE_DRIVE    = 1;
    private const STATE_RECOVERY = 2;

    // Detection thresholds (m/s² of gravity-compensated forward accel)
    private const DRIVE_THRESH = 0.25f;
    private const RECOV_THRESH = -0.05f;

    // ─── Sanity Guards ────────────────────────────────────────────────────────
    private const MAX_BOAT_SPEED  = 7.0f;
    private const MIN_STROKE_MS   = 800;
    private const MAX_STROKE_MS   = 8000;
    private const MIN_STROKE_DIST = 3.0f;
    private const TIMEOUT_MS      = 5000;

    // ─── Sub-systems ─────────────────────────────────────────────────────────
    // Public so RowingView can read calibrator.phase and calibrator.getStatusString()
    var calibrator as AxisCalibrator;

    // ─── Class Fields (type annotations ARE valid here) ───────────────────────
    private var _accelFiltered as Float;
    private var _velocity      as Float;
    private var _lastVelocity  as Float;
    private var _lastSampleMs  as Number;

    private var _gpsSpeed    as Float;
    private var _hasValidGps as Boolean;
    private var _lastGpsMs   as Number;

    private var _state      as Number;
    private var _catchMs    as Number;
    private var _strokeDist as Float;

    var currentHr as Number?; 


    // ─── Public Outputs ───────────────────────────────────────────────────────
    var displayPaceSeconds as Number or Null;
    var strokeCount        as Number;
    var isPaused           as Boolean;
    var currentSpeedMs     as Float;
    var strokeRateSpm      as Number or Null;

    // ─────────────────────────────────────────────────────────────────────────

    function initialize() {
        calibrator = new AxisCalibrator();

        _accelFiltered = 0.0f;
        _velocity      = 0.0f;
        _lastVelocity  = 0.0f;
        _lastSampleMs  = System.getTimer();

        _gpsSpeed    = -1.0f;
        _hasValidGps = false;
        _lastGpsMs   = 0;

        _state      = STATE_IDLE;
        _catchMs    = -1;
        _strokeDist = 0.0f;

        displayPaceSeconds = null;
        strokeCount        = 0;
        isPaused           = true;
        currentSpeedMs     = 0.0f;
        strokeRateSpm      = null;
    }

    function updateHr(hr as Number?) as Void {
        currentHr = hr;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC API
    // ─────────────────────────────────────────────────────────────────────────

function processAccelBatch(accelData as Sensor.AccelerometerData) as Void {
        var xs = accelData.x;
        var ys = accelData.y;
        var zs = accelData.z;

        if (xs == null || xs.size() == 0) { return; }

        for (var i = 0; i < xs.size(); i++) {

            // ── Determine sample timestamp ─────────────────────────────────
            // 25 Hz sample rate = 40ms per sample. 
            // We increment the time manually for each sample in the batch.
            var sampleMs = _lastSampleMs + 40; 
            
            // ── Delegate to calibrator ────────────────────────────────────
            var result = calibrator.processSample(xs[i], ys[i], zs[i]);

            if (result.isReady || calibrator.phase == AxisCalibrator.PHASE_LEARNING) {
                _processSingleSample(result.linearForwardMs2, sampleMs);
            } else {
                _lastSampleMs = sampleMs;
                isPaused = true;
            }
        }
    }

    
    function updateGpsSpeed(speedMs as Float) as Void {
        _lastGpsMs   = System.getTimer();
        _hasValidGps = (speedMs >= 0.0f);
        if (_hasValidGps) { _gpsSpeed = speedMs; }
    }

    function getPaceString() as String {
        if (!calibrator.isReady())                   { return "--:--"; }
        if (isPaused || displayPaceSeconds == null)  { return "--:--"; }

        var s = displayPaceSeconds as Number;
        var m = s / 60;
        s = s % 60;
        return m.format("%d") + ":" + s.format("%02d");
    }

    function getStateLabel() as String {
        if (_state == STATE_DRIVE)    { return "DRV"; }
        if (_state == STATE_RECOVERY) { return "REC"; }
        return "IDL";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: SIGNAL CHAIN
    // ─────────────────────────────────────────────────────────────────────────

    private function _processSingleSample(forwardMs2 as Float, nowMs as Number) as Void {

        // 1. dt — guard against wrap/gap/duplicate
        var dt = (nowMs - _lastSampleMs) * 0.001f;
        if (dt <= 0.0f || dt > 0.5f) {
            _lastSampleMs = nowMs;
            return;
        }

        // 2. Low-pass filter (vibration rejection)
        _accelFiltered = LPF_ALPHA * forwardMs2 + (1.0f - LPF_ALPHA) * _accelFiltered;

        // 3. Inertial velocity integration
        var inertialVel = _velocity + _accelFiltered * dt;

        // 4. Complementary filter (GPS blend)
        var gpsIsStale = (System.getTimer() - _lastGpsMs) > 3000;
        if (_hasValidGps && !gpsIsStale) {
            _velocity = CF_ALPHA * inertialVel + (1.0f - CF_ALPHA) * _gpsSpeed;
        } else {
            _velocity = inertialVel;
        }

        // 5. Clamp to physical limits
        if (_velocity < 0.0f)           { _velocity = 0.0f; }
        if (_velocity > MAX_BOAT_SPEED) { _velocity = MAX_BOAT_SPEED; }
        currentSpeedMs = _velocity;

        // 6. Trapezoidal distance integration
        if (_catchMs >= 0) {
            _strokeDist += (_lastVelocity + _velocity) * 0.5f * dt;
        }
        _lastVelocity = _velocity;

        // 7. State machine
        _runStateMachine(nowMs);

        // 8. Timeout check
        _checkTimeout(nowMs);

        _lastSampleMs = nowMs;

        if (calibrator.isReady()) { isPaused = false; }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: STATE MACHINE
    // ─────────────────────────────────────────────────────────────────────────

    private function _runStateMachine(nowMs as Number) as Void {
        if (_state == STATE_IDLE) {
            if (_accelFiltered > DRIVE_THRESH) {
                _onCatch(nowMs);
                _state = STATE_DRIVE;
            }
        } else if (_state == STATE_DRIVE) {
            if (_accelFiltered < RECOV_THRESH) {
                _state = STATE_RECOVERY;
            }
        } else if (_state == STATE_RECOVERY) {
            if (_accelFiltered > DRIVE_THRESH) {
                _onCatch(nowMs);
                _state = STATE_DRIVE;
            }
        }
    }

    private function _onCatch(nowMs as Number) as Void {
        if (_catchMs >= 0) {
            var strokeDurationMs = nowMs - _catchMs;

            var durationOk = (strokeDurationMs >= MIN_STROKE_MS)
                          && (strokeDurationMs <= MAX_STROKE_MS);
            var distanceOk = (_strokeDist >= MIN_STROKE_DIST);

            if (durationOk && distanceOk) {
                var strokeDurationSec = strokeDurationMs * 0.001f;
                var avgSpeed = _strokeDist / strokeDurationSec;

                if (avgSpeed > 0.05f) {
                    displayPaceSeconds = (500.0f / avgSpeed + 0.5f).toNumber();
                }

                strokeRateSpm = (60000.0f / strokeDurationMs.toFloat() + 0.5f).toNumber();
                strokeCount++;
                isPaused = false;
            }
        }

        // Tell calibrator a stroke was detected (advances PHASE_LEARNING counter)
        calibrator.notifyStrokeDetected();

        _catchMs    = nowMs;
        _strokeDist = 0.0f;
    }

    private function _checkTimeout(nowMs as Number) as Void {
        if (_catchMs < 0) { return; }

        if ((nowMs - _catchMs) > TIMEOUT_MS) {
            isPaused           = true;
            displayPaceSeconds = null;
            strokeRateSpm      = null;
            _state             = STATE_IDLE;
        }
    }
}
