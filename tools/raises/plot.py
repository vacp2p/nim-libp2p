import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import json

data = []
with open("exceptions.json") as f:
    line = f.readline()
    while line:
        data.append(json.loads(line))
        line = f.readline()

data = pd.DataFrame(data)
labels = data["name"].unique()
count = data.groupby(data["name"]).size().reindex(labels)
data = {"count": count}
data = pd.DataFrame(data)

sns.heatmap(data, annot=True, fmt="g", cmap='viridis')
plt.show()
