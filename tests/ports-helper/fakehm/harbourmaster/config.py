import os

HM_MAX_TEMP_SIZE = int(os.environ.get("FAKE_HM_MAX_TEMP", str(100 << 20)))
HM_SOURCE_DEFAULTS = {
    "020_portmaster.source.json": '{"prefix": "pm", "name": "Invented One"}\n',
    "021_portmaster.multiverse.source.json": '{"prefix": "pmmv", "name": "Invented Two"}\n',
}
