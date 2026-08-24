import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Application;
import Toybox.Attention;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class SaunaLogGarminConnectionListener extends Communications.ConnectionListener {
    private var _sourceId as String;

    function initialize(sourceId as String) {
        Communications.ConnectionListener.initialize();
        _sourceId = sourceId;
    }

    public function onComplete() as Void {
        Application.Storage.deleteValue("saunaLog.pendingSession");
    }
    public function onError() as Void {}
}

class SaunaLogInputDelegate extends WatchUi.InputDelegate {
    private var _view as SaunaLogGarminView;

    function initialize(view as SaunaLogGarminView) {
        InputDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.selectAction();
        return true;
    }

    function onTap(event as WatchUi.ClickEvent) as Boolean {
        var point = event.getCoordinates();
        _view.tapAction(point[0], point[1]);
        return true;
    }

    function onBack() as Boolean {
        _view.backAction();
        return true;
    }

    function onNextPage() as Boolean {
        _view.nextPage();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.previousPage();
        return true;
    }

    function onSwipe(event as WatchUi.SwipeEvent) as Boolean {
        if (event.getDirection() == WatchUi.SWIPE_UP || event.getDirection() == WatchUi.SWIPE_LEFT) {
            _view.nextPage();
        } else {
            _view.previousPage();
        }
        return true;
    }
}

class SaunaLogGarminView extends WatchUi.View {
    private const STATE_LOCKED = -1;
    private const STATE_TYPE = 0;
    private const STATE_TIMER = 1;
    private const STATE_ACTIVE = 2;
    private const STATE_FINISHED = 3;

    private const CYAN = 0x28A8BB;
    private const ORANGE = 0xF15A35;
    private const GREEN = 0x30D158;
    private const MUTED = 0x8A929B;
    private const CARD = 0x171B21;
    private const CARD_EDGE = 0x2B323B;
    private const SAUNA_TEMP_KEY = "sauna.temp.c";
    private const SAUNA_HUMIDITY_KEY = "sauna.humidity";
    private const STEAM_TEMP_KEY = "steam.temp.c";
    private const STEAM_HUMIDITY_KEY = "steam.humidity";
    private const PENDING_SESSION_KEY = "saunaLog.pendingSession";

    private var _state as Number = STATE_TYPE;
    private var _activityName as String = "Sauna";
    private var _activitySelected as Boolean = false;
    private var _selectedPreset as Number = 1;
    private var _presets as Array<Number> = [300, 600, 900, 1200];
    private var _remaining as Number = 600;
    private var _endTime as Number = 0;
    private var _session as ActivityRecording.Session?;
    private var _timer as Timer.Timer?;
    private var _heartRate as Numeric?;
    private var _averageHeartRate as Numeric?;
    private var _maxHeartRate as Numeric?;
    private var _totalCalories as Numeric = 0;
    private var _estimatedActiveCalories as Numeric = 0;
    private var _energyRate as Numeric = 0.0f;
    private var _hadColdShower as Boolean = false;
    private var _width as Number = 300;
    private var _height as Number = 300;
    private var _isRoundScreen as Boolean = false;
    private var _activePage as Number = 0;
    private var _temperatureC as Number = 80;
    private var _humidity as Number = 10;
    private var _conditionsEdited as Boolean = false;
    private var _isAuthorized as Boolean = false;
    private var _sessionStartTime as Number = 0;
    private var _sessionSourceId as String = "";
    private var _plannedDurationSeconds as Number = 0;

    function initialize() {
        View.initialize();
        _remaining = _presets[_selectedPreset];
        try {
            _isRoundScreen = System.SCREEN_SHAPE_ROUND == System.getDeviceSettings().screenShape;
        } catch (e) {
            _isRoundScreen = false;
        }
        _timer = new Timer.Timer();
        _isAuthorized = Application.Storage.getValue("saunaLog.authorized") == true;
        if (!_isAuthorized) {
            _state = STATE_LOCKED;
        }
        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        }
        loadConditionDefaults();
        if (Toybox has :Sensor) {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.enableSensorEvents(method(:onSensor));
        }
    }

    function onShow() as Void {
        transmitPendingSession();
        WatchUi.requestUpdate();
    }

    function onHide() as Void {
        if (_timer != null) {
            (_timer as Timer.Timer).stop();
        }
    }

    function selectAction() as Void {
        if (!_isAuthorized) {
            return;
        }
        if (_state == STATE_TYPE) {
            if (_activitySelected) {
                _state = STATE_TIMER;
            }
        } else if (_state == STATE_TIMER) {
            startSession();
        } else if (_state == STATE_ACTIVE) {
            if (_activePage == 0) {
                _activePage = 1;
            } else {
                // Controls are activated by their explicit touch regions.
                // Do not treat a generic select event as Stop or Cold Shower.
            }
        } else if (_state == STATE_FINISHED) {
            addTime();
        }
        WatchUi.requestUpdate();
    }

    function nextPage() as Void {
        if (!_isAuthorized) {
            return;
        }
        if (_state == STATE_TYPE) {
            if (_activitySelected) {
                _state = STATE_TIMER;
            }
        } else if (_state == STATE_ACTIVE) {
            // Scroll only between the live metrics and controls. Heat settings
            // is opened explicitly from the controls page.
            if (_activePage == 0) {
                _activePage = 1;
            }
        }
        WatchUi.requestUpdate();
    }

    function previousPage() as Void {
        if (!_isAuthorized) {
            return;
        }
        if (_state == STATE_TIMER) {
            _state = STATE_TYPE;
        } else if (_state == STATE_ACTIVE) {
            if (_activePage == 1) {
                _activePage = 0;
            } else if (_activePage == 2) {
                _activePage = 1;
            }
        } else if (_state == STATE_FINISHED) {
            reset();
        }
        WatchUi.requestUpdate();
    }

    function tapAction(x as Number, y as Number) as Void {
        if (!_isAuthorized) {
            return;
        }
        var width = 0;
        var height = 0;
        try {
            width = _width;
            height = _height;
        } catch (e) {
            width = 300;
            height = 300;
        }

        if (_state == STATE_TYPE) {
            if (y > height * 0.22 && y < height * 0.55) {
                _activityName = "Sauna";
                _activitySelected = true;
                _state = STATE_TIMER;
            } else if (y >= height * 0.55) {
                _activityName = "Steam Room";
                _activitySelected = true;
                _state = STATE_TIMER;
            }
        } else if (_state == STATE_TIMER) {
            if (y > height * 0.20 && y < height * 0.70) {
                _selectedPreset = x < width / 2 ? 0 : 1;
                if (y > height * 0.46) {
                    _selectedPreset = x < width / 2 ? 2 : 3;
                }
                _remaining = _presets[_selectedPreset];
            } else if (y >= height * 0.70) {
                if (_activitySelected) {
                    startSession();
                }
            }
        } else if (_state == STATE_ACTIVE) {
            if (_activePage == 0) {
                if (y >= height - 46) {
                    _activePage = 1;
                }
            } else if (_activePage == 1) {
                var stopTop = height - 54;
                var coldTop = stopTop - 34;
                var heatTop = coldTop - 34;
                if (y >= heatTop && y < heatTop + 28) {
                    _activePage = 2;
                } else if (y >= coldTop && y < coldTop + 28) {
                    _hadColdShower = !_hadColdShower;
                } else if (y >= stopTop) {
                    stopSession();
                }
            } else if (_activePage == 2) {
                if (y >= height - 58) {
                    saveConditionDefaults();
                    _activePage = 0;
                } else {
                    adjustConditions(x, y);
                }
            }
        } else if (_state == STATE_FINISHED) {
            if (y >= height - 70) {
                stopSession();
            } else if (y > height * 0.55) {
                addTime();
            } else {
                stopSession();
            }
        }
        WatchUi.requestUpdate();
    }

    function backAction() as Void {
        if (!_isAuthorized) {
            return;
        }
        if (_state == STATE_TIMER) {
            _state = STATE_TYPE;
        } else if (_state == STATE_ACTIVE && _activePage == 2) {
            _activePage = 1;
        } else if (_state == STATE_ACTIVE && _activePage == 1) {
            _activePage = 0;
        } else if (_state != STATE_TYPE) {
            stopSession();
        }
        WatchUi.requestUpdate();
    }

    function startSession() as Void {
        if (!_isAuthorized || _session != null || !_activitySelected) {
            return;
        }

        _remaining = _presets[_selectedPreset];
        _endTime = Time.now().value() + _remaining;
        _sessionStartTime = Time.now().value();
        _sessionSourceId = _sessionStartTime.format("%d") + "-" + _activityName;
        _plannedDurationSeconds = _presets[_selectedPreset];
        _heartRate = null;
        _averageHeartRate = null;
        _maxHeartRate = null;
        _totalCalories = 0;
        _estimatedActiveCalories = 0;
        _energyRate = 0.0f;
        _hadColdShower = false;
        _activePage = 0;
        loadConditionDefaults();
        _conditionsEdited = false;

        if (Toybox has :ActivityRecording) {
            _session = ActivityRecording.createSession({
                :name=>"Sauna Log - " + _activityName,
                :sport=>Activity.SPORT_GENERIC,
                :subSport=>Activity.SUB_SPORT_GENERIC
            });
            (_session as ActivityRecording.Session).start();
        }

        _state = STATE_ACTIVE;
        if (_timer != null) {
            (_timer as Timer.Timer).start(method(:onTimer), 1000, true);
        }
        vibrate();
    }

    function addTime() as Void {
        if (_state == STATE_FINISHED) {
            _endTime = Time.now().value() + _presets[_selectedPreset];
            _remaining = _presets[_selectedPreset];
            _plannedDurationSeconds += _presets[_selectedPreset];
            _state = STATE_ACTIVE;
            if (_timer != null) {
                (_timer as Timer.Timer).start(method(:onTimer), 1000, true);
            }
            return;
        }
    }

    function stopSession() as Void {
        var endTime = Time.now().value();
        updateActivityMetrics();
        if (_session != null) {
            var session = _session as ActivityRecording.Session;
            if (session.isRecording()) {
                session.stop();
                session.save();
            }
            _session = null;
        }
        transmitCompletedSession(endTime);
        if (_timer != null) {
            (_timer as Timer.Timer).stop();
        }
        // An early stop is complete, not an invitation to start another round.
        // The add-time screen is reserved for a naturally completed timer.
        reset();
        vibrate();
        WatchUi.requestUpdate();
    }

    function transmitCompletedSession(endTime as Number) as Void {
        if (_sessionStartTime <= 0 || _sessionSourceId == "") {
            return;
        }

        var average = _averageHeartRate == null ? 0 : (_averageHeartRate as Number);
        var maximum = _maxHeartRate == null ? 0 : (_maxHeartRate as Number);
        var activeCalories = _estimatedActiveCalories == null ? 0 : (_estimatedActiveCalories as Number);
        var totalCalories = _totalCalories == null ? 0 : (_totalCalories as Number);
        var payload = {
            "type" => "saunaLog.session",
            "sourceId" => _sessionSourceId,
            "activityType" => _activityName == "Steam Room" ? "steamRoom" : "sauna",
            "startTime" => _sessionStartTime,
            "endTime" => endTime,
            "hadColdShower" => _hadColdShower,
            "plannedDurationSeconds" => _plannedDurationSeconds,
            "averageHeartRate" => average,
            "maxHeartRate" => maximum,
            "activeCalories" => activeCalories,
            "totalCalories" => totalCalories,
            "temperatureCelsius" => _temperatureC,
            "humidityPercent" => _humidity,
            "environmentWasDefault" => !_conditionsEdited
        };

        Application.Storage.setValue(PENDING_SESSION_KEY, payload);
        transmitPendingSession();
    }

    function transmitPendingSession() as Void {
        var payload = Application.Storage.getValue(PENDING_SESSION_KEY);
        if (payload == null || !(payload instanceof Dictionary)) {
            return;
        }
        try {
            var sourceId = (payload as Dictionary)["sourceId"] as String;
            Communications.transmit(payload, {}, new SaunaLogGarminConnectionListener(sourceId));
        } catch (e) {
            // The Garmin activity remains saved locally if the phone is unavailable.
        }
    }

    function reset() as Void {
        _sessionStartTime = 0;
        _sessionSourceId = "";
        _plannedDurationSeconds = 0;
        _state = STATE_TYPE;
        _activitySelected = false;
        _activePage = 0;
        _remaining = _presets[_selectedPreset];
        _hadColdShower = false;
    }

    function onTimer() as Void {
        if (_state != STATE_ACTIVE) {
            return;
        }

        _remaining = _endTime - Time.now().value();
        if (_remaining < 0) { _remaining = 0; }
        updateActivityMetrics();
        if (_remaining <= 0) {
            if (_timer != null) {
                (_timer as Timer.Timer).stop();
            }
            _state = STATE_FINISHED;
            vibrate();
        }
        WatchUi.requestUpdate();
    }

    function onSensor(info as Sensor.Info) as Void {
        if (info.heartRate != null && info.heartRate > 0) {
            _heartRate = info.heartRate;
            if (_averageHeartRate == null) {
                _averageHeartRate = _heartRate;
            } else {
                _averageHeartRate = ((_averageHeartRate as Number) * 0.9) + ((_heartRate as Number) * 0.1);
            }
            if (_maxHeartRate == null || (_heartRate as Number) > (_maxHeartRate as Number)) {
                _maxHeartRate = _heartRate;
            }
        }
    }

    function updateActivityMetrics() as Void {
        try {
            var info = Activity.getActivityInfo();
            if (info.currentHeartRate != null) {
                _heartRate = info.currentHeartRate;
            }
            if (info.averageHeartRate != null) {
                _averageHeartRate = info.averageHeartRate;
            }
            if (info.maxHeartRate != null) {
                _maxHeartRate = info.maxHeartRate;
            }
            if (info.calories != null) {
                _totalCalories = info.calories;
            }
            if (info.energyExpenditure != null) {
                _energyRate = info.energyExpenditure;
                _estimatedActiveCalories = (_energyRate * (_presets[_selectedPreset] - _remaining)) / 60.0f;
            }
        } catch (e) {
            // Some older devices expose fewer live activity fields.
        }
    }

    function vibrate() as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([
                new Attention.VibeProfile(100, 100),
                new Attention.VibeProfile(25, 100),
                new Attention.VibeProfile(100, 100)
            ]);
        }
    }

    function onUpdate(dc as Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        _width = width;
        _height = height;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        if (!_isAuthorized) {
            drawLockedScreen(dc, width, height);
        } else if (_state == STATE_TYPE) {
            drawTypeScreen(dc, width, height);
        } else if (_state == STATE_TIMER) {
            drawTimerScreen(dc, width, height);
        } else if (_state == STATE_ACTIVE) {
            if (_activePage == 0) {
                drawActiveMetricsScreen(dc, width, height);
            } else if (_activePage == 1) {
                drawActiveControlsScreen(dc, width, height);
            } else {
                drawActiveConditionsScreen(dc, width, height);
            }
        } else {
            drawFinishedScreen(dc, width, height);
        }
    }

    function onPhoneMessage(message as Communications.PhoneAppMessage) as Void {
        if (message == null || message.data == null || !(message.data instanceof Dictionary)) {
            return;
        }
        var payload = message.data as Dictionary;
        if (payload["type"] != "saunaLog.entitlement" || payload["authorized"] != true) {
            return;
        }
        _isAuthorized = true;
        Application.Storage.setValue("saunaLog.authorized", true);
        _state = STATE_TYPE;
        WatchUi.requestUpdate();
    }

    function drawLockedScreen(dc as Dc, width as Number, height as Number) as Void {
        drawAccentLine(dc, width);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 104, Graphics.FONT_MEDIUM, "Sauna Log", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 140, Graphics.FONT_XTINY, "Open Sauna Log on iPhone", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(width / 2, 158, Graphics.FONT_XTINY, "to activate", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawTypeScreen(dc as Dc, width as Number, height as Number) as Void {
        drawAccentLine(dc, width);
        var margin = 14;
        var cardWidth = width - (margin * 2);
        var cardHeight = largerOf(62, smallerOf(84, (height - 118) / 2));
        drawChoice(dc, margin, 62, cardWidth, cardHeight, "Sauna", "Dry heat", _activityName == "Sauna" && _activitySelected, CYAN);
        drawChoice(dc, margin, 70 + cardHeight, cardWidth, cardHeight, "Steam Room", "Humid heat", _activityName == "Steam Room" && _activitySelected, ORANGE);
    }

    function drawTimerScreen(dc as Dc, width as Number, height as Number) as Void {
        drawAccentLine(dc, width);
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 68, Graphics.FONT_XTINY, _activityName, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        var labels = ["05:00", "10:00", "15:00", "20:00"];
        var margin = 14;
        var gap = 8;
        var buttonWidth = (width - (margin * 2) - gap) / 2;
        var buttonHeight = largerOf(38, smallerOf(46, (height - 146) / 2));
        var positions = [[margin, 82], [margin + buttonWidth + gap, 82], [margin, 90 + buttonHeight], [margin + buttonWidth + gap, 90 + buttonHeight]];
        for (var i = 0; i < 4; i++) {
            drawButton(dc, positions[i][0], positions[i][1], buttonWidth, buttonHeight, labels[i], i == _selectedPreset ? GREEN : CARD, Graphics.COLOR_WHITE);
        }
        drawActionBar(dc, width, height, "START");
    }

    function drawActiveMetricsScreen(dc as Dc, width as Number, height as Number) as Void {
        drawAccentLine(dc, width);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 72, Graphics.FONT_MEDIUM, formatTime(_remaining), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        var margin = 14;
        var gap = 8;
        var metricWidth = (width - (margin * 2) - gap) / 2;
        var metricHeight = largerOf(48, smallerOf(54, (height - 196) / 2));
        var metricTop = 98;
        drawMetric(dc, margin, metricTop, metricWidth, metricHeight, "HR", _heartRate == null ? "--" : (_heartRate as Number).format("%d") + " bpm", CYAN);
        drawMetric(dc, margin + metricWidth + gap, metricTop, metricWidth, metricHeight, "TOTAL", (_totalCalories as Number).format("%d") + " kcal", ORANGE);
        drawMetric(dc, margin, metricTop + metricHeight + 12, metricWidth, metricHeight, "ACTIVE", (_estimatedActiveCalories as Number).format("%d") + " kcal", GREEN);
        drawMetric(dc, margin + metricWidth + gap, metricTop + metricHeight + 12, metricWidth, metricHeight, "AVG", _averageHeartRate == null ? "--" : (_averageHeartRate as Number).format("%d") + " bpm", MUTED);
        drawScrollChevron(dc, width / 2, height - 14, false);
    }

    function drawActiveControlsScreen(dc as Dc, width as Number, height as Number) as Void {
        drawAccentLine(dc, width);
        drawScrollChevron(dc, width / 2, 60, true);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 74, Graphics.FONT_MEDIUM, formatTime(_remaining), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 100, Graphics.FONT_XTINY, _activityName, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        var buttonHeight = 28;
        var stopTop = height - 54;
        var coldTop = stopTop - 34;
        var heatTop = coldTop - 34;
        drawButton(dc, 14, heatTop, width - 28, buttonHeight, "Heat Settings", CARD, Graphics.COLOR_WHITE);
        drawButton(dc, 14, coldTop, width - 28, buttonHeight, "Cold Shower", _hadColdShower ? GREEN : CARD, Graphics.COLOR_WHITE);
        drawButton(dc, 14, stopTop, width - 28, buttonHeight, "Stop Session", ORANGE, Graphics.COLOR_WHITE);
    }

    function drawActiveConditionsScreen(dc as Dc, width as Number, height as Number) as Void {
        drawAccentLine(dc, width);
        drawConditionRow(dc, width, 76, "TEMP", _temperatureC.format("%d") + " C");
        drawConditionRow(dc, width, 132, "HUMIDITY", _humidity.format("%d") + " %");
        drawButton(dc, 14, height - 58, width - 28, 34, "SAVE", GREEN, Graphics.COLOR_WHITE);
    }

    function drawConditionRow(dc as Dc, width as Number, y as Number, label as String, value as String) as Void {
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(24, y + 17, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2 + 4, y + 17, Graphics.FONT_SMALL, value, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        drawButton(dc, width - 78, y + 1, 27, 32, "-", CARD, Graphics.COLOR_WHITE);
        drawButton(dc, width - 45, y + 1, 27, 32, "+", GREEN, Graphics.COLOR_WHITE);
    }

    function adjustConditions(x as Number, y as Number) as Void {
        if (x < _width - 82 || x > _width - 12) {
            return;
        }
        var change = x > _width - 48 ? 1 : -1;
        if (y >= 76 && y < 122) {
            _temperatureC = largerOf(0, _temperatureC + change);
            _conditionsEdited = true;
        } else if (y >= 132 && y < 178) {
            _humidity = smallerOf(100, largerOf(0, _humidity + change));
            _conditionsEdited = true;
        }
        saveConditionDefaults();
    }

    function loadConditionDefaults() as Void {
        if (_activityName == "Sauna") {
            _temperatureC = storedNumber(SAUNA_TEMP_KEY, 80);
            _humidity = storedNumber(SAUNA_HUMIDITY_KEY, 10);
        } else {
            _temperatureC = storedNumber(STEAM_TEMP_KEY, 45);
            _humidity = storedNumber(STEAM_HUMIDITY_KEY, 90);
        }
    }

    function saveConditionDefaults() as Void {
        if (_activityName == "Sauna") {
            Application.Storage.setValue(SAUNA_TEMP_KEY, _temperatureC);
            Application.Storage.setValue(SAUNA_HUMIDITY_KEY, _humidity);
        } else {
            Application.Storage.setValue(STEAM_TEMP_KEY, _temperatureC);
            Application.Storage.setValue(STEAM_HUMIDITY_KEY, _humidity);
        }
    }

    function storedNumber(key as String, fallback as Number) as Number {
        var stored = Application.Storage.getValue(key);
        return stored == null ? fallback : stored as Number;
    }

    function drawFinishedScreen(dc as Dc, width as Number, height as Number) as Void {
        drawHeader(dc, width, "Session saved");
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 62, Graphics.FONT_MEDIUM, _activityName, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(width / 2, 92, Graphics.FONT_SMALL, "Add another round?", Graphics.TEXT_JUSTIFY_CENTER);
        drawButton(dc, 12, height - 112, width - 24, 44, "ADD MORE TIME", ORANGE, Graphics.COLOR_WHITE);
        drawButton(dc, 12, height - 58, width - 24, 38, "DONE", CARD, Graphics.COLOR_WHITE);
    }

    function drawHeader(dc as Dc, width as Number, title as String) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, 24, Graphics.FONT_SMALL, title, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        drawAccentLine(dc, width);
    }

    function drawAccentLine(dc as Dc, width as Number) as Void {
        dc.setColor(CYAN, CYAN);
        dc.fillRoundedRectangle(18, 50, width - 36, 3, 1);
    }

    function drawChoice(dc as Dc, x as Number, top as Number, width as Number, height as Number, title as String, subtitle as String, selected as Boolean, accent as Number) as Void {
        var color = selected ? GREEN : CARD;
        var edgeInset = 0;
        if (_isRoundScreen && (top <= 62 || top + height >= _height - 54)) {
            edgeInset = 7;
        }
        x += edgeInset;
        width -= edgeInset * 2;
        var radius = smallerOf(12, height / 3);
        if (_isRoundScreen && (top <= 62 || top + height >= _height - 54)) {
            radius = smallerOf(width / 2, height / 2);
        }

        dc.setColor(color, color);
        dc.fillRoundedRectangle(x, top, width, height, radius);
        dc.setColor(CARD_EDGE, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(x, top, width, height, radius);

        var centerY = top + height / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width / 2, centerY - 9, Graphics.FONT_SMALL, title, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(selected ? Graphics.COLOR_WHITE : MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width / 2, centerY + 13, Graphics.FONT_XTINY, subtitle, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawMetric(dc as Dc, x as Number, y as Number, width as Number, height as Number, label as String, value as String, accent as Number) as Void {
        drawButtonSurface(dc, x, y, width, height, CARD);
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width / 2, y + 10, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width / 2, y + height - 15, Graphics.FONT_SMALL, value, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawButton(dc as Dc, x as Number, y as Number, width as Number, height as Number, label as String, background as Number, foreground as Number) as Void {
        // Round displays lose usable width near the bezel. Keep controls clear of it.
        var edgeInset = 0;
        if (_isRoundScreen && (y <= 62 || y + height >= _height - 54)) {
            edgeInset = 7;
        }
        x += edgeInset;
        width -= edgeInset * 2;
        var radius = height / 2;
        drawButtonSurface(dc, x, y, width, height, background);
        dc.setColor(foreground, Graphics.COLOR_TRANSPARENT);
        var font = (label == "Cold Shower" || label == "Heat Settings" || label == "Stop Session") ? Graphics.FONT_XTINY : Graphics.FONT_SMALL;
        dc.drawText(x + width / 2, y + height / 2, font, label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawButtonSurface(dc as Dc, x as Number, y as Number, width as Number, height as Number, background as Number) as Void {
        var radius = height / 2;
        dc.setColor(background, background);
        dc.fillRoundedRectangle(x, y, width, height, radius);
        dc.setColor(CARD_EDGE, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(x, y, width, height, radius);
    }

    function drawMultilineButton(dc as Dc, x as Number, y as Number, width as Number, height as Number, firstLine as String, secondLine as String, background as Number, foreground as Number) as Void {
        var edgeInset = 0;
        if (_isRoundScreen && (y <= 62 || y + height >= _height - 54)) {
            edgeInset = 7;
        }
        x += edgeInset;
        width -= edgeInset * 2;
        drawButtonSurface(dc, x, y, width, height, background);
        dc.setColor(foreground, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width / 2, y + height / 2 - 8, Graphics.FONT_XTINY, firstLine, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x + width / 2, y + height / 2 + 8, Graphics.FONT_XTINY, secondLine, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawActionBar(dc as Dc, width as Number, height as Number, label as String) as Void {
        drawButton(dc, 14, height - 42, width - 28, 32, label, ORANGE, Graphics.COLOR_WHITE);
    }

    function drawFooter(dc as Dc, width as Number, height as Number, label as String) as Void {
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, height - 24, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawPageHint(dc as Dc, width as Number, height as Number, label as String) as Void {
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width / 2, height - 14, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawScrollChevron(dc as Dc, centerX as Number, centerY as Number, pointsUp as Boolean) as Void {
        dc.setColor(MUTED, Graphics.COLOR_TRANSPARENT);
        var halfWidth = 5;
        var halfHeight = 3;
        if (pointsUp) {
            dc.drawLine(centerX - halfWidth, centerY + halfHeight, centerX, centerY - halfHeight);
            dc.drawLine(centerX, centerY - halfHeight, centerX + halfWidth, centerY + halfHeight);
        } else {
            dc.drawLine(centerX - halfWidth, centerY - halfHeight, centerX, centerY + halfHeight);
            dc.drawLine(centerX, centerY + halfHeight, centerX + halfWidth, centerY - halfHeight);
        }
    }

    function formatTime(seconds as Number) as String {
        var mins = seconds / 60;
        var secs = seconds % 60;
        return mins.format("%02d") + ":" + secs.format("%02d");
    }

    function largerOf(first as Number, second as Number) as Number {
        return first > second ? first : second;
    }

    function smallerOf(first as Number, second as Number) as Number {
        return first < second ? first : second;
    }
}
