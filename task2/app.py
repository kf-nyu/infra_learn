from flask import Flask
import os

app = Flask(__name__)


@app.route("/")
def index():
    app_name = os.getenv("APP_NAME")

    if app_name is None:
        return "Hello World!"
    else:
        return f"Hello World! I'm {app_name}"
