import Toybox.Lang;
using Toybox.WatchUi;

class speedcoachDelegate extends WatchUi.BehaviorDelegate {

    var _processor;

    function initialize(processor) {
        BehaviorDelegate.initialize();
        _processor = processor;
    }

    function onMenu() as Boolean {
        WatchUi.pushView(new Rez.Menus.MainMenu(), new speedcoachMenuDelegate(), WatchUi.SLIDE_UP);
        return true;
    }
    
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        // if (_processor != null) {
        //     _processor.calibrator.triggerRecalibration();
        //     WatchUi.requestUpdate();
        // }
        return false;
    }
}