import argparse
import os

import joblib
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

MODEL_EXTENSIONS = (".joblib", ".pkl", ".pickle")

parser = argparse.ArgumentParser()
parser.add_argument("--model_name", required=True)
parser.add_argument("--model_dir", required=True)
parser.add_argument("--http_port", type=int, default=8080)
args = parser.parse_args()

model = None
app = FastAPI()


def load_model():
    candidates = [
        f for f in os.listdir(args.model_dir) if f.endswith(MODEL_EXTENSIONS)
    ]
    if len(candidates) != 1:
        raise RuntimeError(
            f"Expected exactly one model file in {args.model_dir}, found: {candidates}"
        )
    return joblib.load(os.path.join(args.model_dir, candidates[0]))


@app.get("/")
def health():
    return {"status": "ok"}


@app.get(f"/v1/models/{args.model_name}")
def model_ready():
    return {"name": args.model_name, "ready": model is not None}


@app.post(f"/v1/models/{args.model_name}:predict")
async def predict(request: Request):
    body = await request.json()
    predictions = model.predict(body["instances"]).tolist()
    return JSONResponse(
        {
            "predictions": predictions,
            "served_by": "custom-sklearn-runtime-lab",
        }
    )


if __name__ == "__main__":
    model = load_model()
    uvicorn.run(app, host="0.0.0.0", port=args.http_port)
