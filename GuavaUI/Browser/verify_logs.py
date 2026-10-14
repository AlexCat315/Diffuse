"""Log protocol replay and Inspector controls against real native/Wasm hosts."""
import json


def log_panel_checks(page, target):
    target.wait_for_function("inspector.session.logs.logEntries.some(e => e.process?.runID && e.sequence > 0)")
    records = target.evaluate("inspector.session.logs.logEntries.filter(e => e.process)")
    assert all(record["location"]["file"] and record["process"]["runID"] for record in records)
    target.locator("#pauseLog").click()
    before = target.locator("#log").inner_text()
    target.evaluate("""() => {
        const record = {sequence:90000, timestamp:Date.now()/1000, level:'error', label:'com.guava.test.logs',
          message:'<script>literal text</script>', metadata:{nested:{value:'search-needle'}},
          location:{source:'acceptance',file:'LogCheck.swift',function:'check()',line:42},
          process:{pid:42,name:'acceptance',runID:'inspector-acceptance'}};
        inspector.logs.appendLog(record); inspector.logs.appendLog(record);
    }""")
    assert target.locator("#log").inner_text() == before
    assert target.evaluate("inspector.session.logs.logEntries.filter(e => e.sequence === 90000).length") == 1
    target.locator("#pauseLog").click()
    target.locator("#logModule").fill("com.guava.test")
    target.locator("#logLevel").select_option("error")
    target.locator("#logSearch").fill("search-needle")
    target.locator("#log summary").filter(has_text="<script>literal text</script>").wait_for()
    assert target.locator("#log script").count() == 0
    target.locator("#log summary").click()
    assert "LogCheck.swift" in target.locator("#log pre").inner_text()
    with page.expect_download() as download:
        target.locator("#exportLog").click()
    exported = [json.loads(line) for line in open(download.value.path(), encoding="utf8") if line.strip()]
    assert len(exported) == 1 and exported[0]["metadata"]["nested"]["value"] == "search-needle"
    target.locator("#logSearch").fill("")
    target.locator("#logModule").fill("")
    target.locator("#logLevel").select_option("info")
