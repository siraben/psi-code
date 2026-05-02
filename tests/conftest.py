def pytest_addoption(parser):
    group = parser.getgroup("psi smoke")
    group.addoption("--psi", default="build/psi",
                    help="path to psi binary")
    group.addoption("--filter", default=None,
                    help="only run smoke tests whose name contains this substring")
    group.addoption("--exclude", action="append", default=[],
                    help="skip smoke tests whose name contains this substring; may be repeated")
    group.addoption("--no-live", action="store_true",
                    help="skip live-agent smoke tests even if ANTHROPIC_API_KEY is set")
