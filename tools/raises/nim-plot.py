import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import re

data = []
# grep for `newException(`
with open("nim-exceptions.txt") as f:
    line = f.readline()
    while line:
        match = re.match( r'.*newException\((\w+)', line, re.M|re.I)
        if match:
            name = match.group(1)
            if name != "exc":
                data.append({"name": match.group(1)})

        line = f.readline()

data = pd.DataFrame(data)
labels = data["name"].unique()
count = data.groupby(data["name"]).size().reindex(labels)
data = {"count": count}
data = pd.DataFrame(data)

sns.heatmap(data, annot=True, fmt="g", cmap='viridis')
plt.show()
