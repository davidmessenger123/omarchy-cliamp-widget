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


if __name__ == "__main__":
    unittest.main()
