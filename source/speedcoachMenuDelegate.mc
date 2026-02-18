import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class speedcoachMenuDelegate extends WatchUi.MenuInputDelegate {

    function initialize() {
        MenuInputDelegate.initialize();
    }

    function onMenuItem(item as Symbol) as Void {
        if (item == :item_1) {
            // var app = Application.getApp();
            // var processor = app._processor; // you may need to expose it via a getter
            // processor.calibrator.triggerRecalibration();
            // WatchUi.requestUpdate();

        } else if (item == :item_2) {
            System.println("item 2");
        }
    }

}