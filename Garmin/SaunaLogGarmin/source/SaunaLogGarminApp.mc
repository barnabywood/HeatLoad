import Toybox.Application;
import Toybox.WatchUi;

class SaunaLogGarminApp extends Application.AppBase {
    private var _view as SaunaLogGarminView?;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new $.SaunaLogGarminView();
        return [_view, new $.SaunaLogInputDelegate(_view)];
    }
}
