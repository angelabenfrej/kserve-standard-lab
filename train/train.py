from dotenv import load_dotenv

load_dotenv()

import mlflow
import mlflow.sklearn
from sklearn.datasets import load_iris
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score
from sklearn.model_selection import train_test_split

mlflow.set_experiment("sklearn-iris")

X, y = load_iris(return_X_y=True)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

with mlflow.start_run() as run:
    model = LogisticRegression(max_iter=200)
    model.fit(X_train, y_train)

    accuracy = accuracy_score(y_test, model.predict(X_test))
    mlflow.log_param("max_iter", 200)
    mlflow.log_metric("accuracy", accuracy)

    model_info = mlflow.sklearn.log_model(
        model, name="model", serialization_format="cloudpickle"
    )

    print(f"run_id: {run.info.run_id}")
    print(f"accuracy: {accuracy}")
    print(f"model artifact_path (storageUri): {model_info.artifact_path}")
