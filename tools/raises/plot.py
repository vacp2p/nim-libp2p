import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import json

data = []
with open("exceptions.json") as f:
    line = f.readline()
    while line:
        j = json.loads(line)

        # Basically it runs up to the end of the first part of the nim stack trace
        # this is good especially cos it is the most relevant in async code as well!
        raiser = ""
        for trace in j["stacktrace"]:
            if trace["procname"] == "":
                break
            raiser = trace["procname"]
        proc = j["stacktrace"][0]["procname"]
        data.append({
            "exception": j["name"],
            "raiser": proc + "/" + raiser
        })

        line = f.readline()

data = pd.DataFrame(data)
procs = data["raiser"].unique()
tab = pd.crosstab(data["exception"], data["raiser"]).reindex(columns=procs)
sns.heatmap(tab, annot=True, fmt="g", cmap='viridis')
plt.show()
