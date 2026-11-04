import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class QmlContractTests(unittest.TestCase):
    def test_qml_has_no_invalid_object_scope_var(self):
        for name in ("Service.qml", "BarWidget.qml"):
            source = (ROOT / name).read_text(encoding="utf-8")
            invalid = re.search(r"(?m)^  var [A-Za-z_$][\w$]*\s*:", source)
            self.assertIsNone(invalid, "%s has an object-scope var: %s" % (name, invalid.group(0) if invalid else ""))

    def test_qml_imports_layouts_when_using_attached_layout(self):
        source = (ROOT / "BarWidget.qml").read_text(encoding="utf-8")
        if "Layout." in source:
            self.assertIn("import QtQuick.Layouts", source)

    def test_sleep_timer_is_shared_and_reaches_the_panel(self):
        service = (ROOT / "Service.qml").read_text(encoding="utf-8")
        widget = (ROOT / "BarWidget.qml").read_text(encoding="utf-8")
        self.assertIn("function setSleep(minutes)", service)
        self.assertIn("function cancelSleep()", service)
        self.assertIn('root.run(["pause"])', service)
        self.assertIn("IpcHandler", service)
        self.assertIn("sleepActive", widget)
        self.assertIn('text: "15m"', widget)
        self.assertIn('text: "30m"', widget)
        self.assertIn('text: "1h"', widget)

    def test_service_exposes_live_queue_management(self):
        service = (ROOT / "Service.qml").read_text(encoding="utf-8")
        for token in (
            "property var queueTracks: []",
            "property int queueTotal: 0",
            "property int queueIndex: -1",
            "property bool queueLoading: false",
            "property bool queueMutating: false",
            "property int queueRevision: 0",
            "property string queueError: \"\"",
            "property bool queueVisible: false",
            "function refreshQueue()",
            "function queuePlay(index)",
            "function queueRemove(index)",
            "function queueMove(index, to)",
            "function queueClear()",
            "function setQueueVisible(value)",
        ):
            self.assertIn(token, service, token)

        # All live-playlist traffic goes through the bounded command runner.
        self.assertIn("root.runWithCallback(", service)
        self.assertIn("root.boundedRunCommand(", service)
        self.assertIn('["remote", "call", "queue.list", "--params", params, "--wait"]', service)
        for operation in ("queue.play", "queue.remove", "queue.move", "queue.clear"):
            self.assertIn(operation, service)
        self.assertIn("Model.parseQueueJob(output)", service)

        # Responses carry a session/revision guard and the panel controls the
        # visibility-gated refresh path.
        self.assertIn("session !== root.queueSession", service)
        self.assertIn("requestRevision !== root.queueRevision", service)
        self.assertIn("mutationRevision !== root.queueMutationRevision", service)
        self.assertIn("playlistRevision !== root.snapshot.playlistRevision", service)
        self.assertIn("root.queueVisible", service)

    def test_bar_panel_renders_a_bounded_queue_section(self):
        widget = (ROOT / "BarWidget.qml").read_text(encoding="utf-8")
        for token in (
            "Model.boundedQueueRows(root.svc.queueTracks, Model.MAX_QUEUE_ROWS)",
            'text: "Queue"',
            'root.queueTotal + (root.queueTotal === 1 ? " track" : " tracks")',
            "root.svc.queuePlay(index)",
            "root.svc.queueRemove(index)",
            "root.svc.queueMove(index, index + delta)",
            "root.svc.queueClear()",
            "onPopupOpenChanged: if (root.svc) root.svc.setQueueVisible(root.popupOpen)",
            '"Move up"',
            '"Move down"',
            '"Remove from queue"',
            '"Refresh queue"',
            '"Clear the queue"',
            '"Queue is empty"',
            '"Showing first "',
            "queueRow.track.title",
            "queueRow.track.artist",
            "Model.formatTime(queueRow.track.duration)",
            "root.queueError",
            "root.queueLoading",
        ):
            self.assertIn(token, widget, token)

    def test_existing_search_favourites_and_no_second_mpris_bridge(self):
        service = (ROOT / "Service.qml").read_text(encoding="utf-8")
        widget = (ROOT / "BarWidget.qml").read_text(encoding="utf-8")
        self.assertIn('placeholderText: "Search stations or tracks…"', widget)
        self.assertIn('text: "Favourites"', widget)
        self.assertIn("function playSearchResult(item)", widget)
        self.assertIn("function toggleFavorite()", widget)
        self.assertNotIn("MediaPlayer2", service)
        self.assertNotIn("MediaPlayer2", widget)


if __name__ == "__main__":
    unittest.main()
