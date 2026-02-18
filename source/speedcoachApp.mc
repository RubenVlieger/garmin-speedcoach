import Toybox.Lang;
using Toybox.Application as App;
using Toybox.WatchUi     as WatchUi;
using Toybox.Sensor      as Sensor;
using Toybox.Activity    as Activity;
using Toybox.Timer       as Timer;
using Toybox.System      as System;

class speedcoachApp extends App.AppBase {

    private var _processor as StrokeProcessor;
    private var _view      as speedcoachView?;
    private var _gpsTimer  as Timer.Timer?;
    private var _hrTimer as Timer.Timer?;
    function initialize() {
        AppBase.initialize();
        _processor = new StrokeProcessor();
    }

    function onStart(state as Dictionary?) as Void {
        _registerSensorListener();
        _startGpsTimer();
        _startHrTimer();
    }

    function onStop(state as Dictionary?) as Void {
        try {
            Sensor.unregisterSensorDataListener();
        } catch (e instanceof Lang.Exception) {}

        if (_gpsTimer != null) {
            _gpsTimer.stop();
        }
        if (_hrTimer != null) {
            _hrTimer.stop();
        }
    }

    private function _startHrTimer() as Void {
        _hrTimer = new Timer.Timer();
        _hrTimer.start(method(:onHrTick), 1000, true);
    }

    function onHrTick() as Void {
        try {
            var actInfo = Activity.getActivityInfo();
            if (actInfo != null && actInfo.currentHeartRate != null) {
                _processor.updateHr(actInfo.currentHeartRate);
            } else {
                _processor.updateHr(null);
            }
        } catch (e instanceof Lang.Exception) {
            _processor.updateHr(null);
        }
    }


    function getInitialView() {
        _view = new speedcoachView(_processor);
        var delegate = new speedcoachDelegate(_processor);
        return [_view, delegate];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SENSOR REGISTRATION
    // ─────────────────────────────────────────────────────────────────────────

    private function _registerSensorListener() as Void {
        var options = {
            :period => 4, // 25 Hz
            :accelerometer => {
                :enabled    => true,
                :sampleRate => 25
            }
        };

        try {
            Sensor.registerSensorDataListener(method(:onSensorData), options);
        } catch (e instanceof Lang.Exception) {
            System.println("Sensor registration failed: " + e.getErrorMessage());
        }
    }

    function onSensorData(data as Sensor.SensorData) as Void {
        if (data.accelerometerData != null) {
            _processor.processAccelBatch(data.accelerometerData);
            WatchUi.requestUpdate();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GPS TIMER
    // ─────────────────────────────────────────────────────────────────────────

    private function _startGpsTimer() as Void {
        _gpsTimer = new Timer.Timer();
        _gpsTimer.start(method(:onGpsTick), 1000, true);
    }

    function onGpsTick() as Void {
        try {
            var actInfo = Activity.getActivityInfo();
            if (actInfo != null && actInfo.currentSpeed != null) {
                _processor.updateGpsSpeed(actInfo.currentSpeed.toFloat());
            } else {
                _processor.updateGpsSpeed(-1.0f);
            }
        } catch (e instanceof Lang.Exception) {
            _processor.updateGpsSpeed(-1.0f);
        }
    }
}