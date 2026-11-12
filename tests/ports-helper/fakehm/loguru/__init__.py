class Logger:
    def remove(self, *args):
        pass

    def add(self, *args, **kwargs):
        return 0

    def debug(self, *args, **kwargs):
        pass

    info = warning = error = exception = debug


logger = Logger()
