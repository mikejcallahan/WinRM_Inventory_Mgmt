# C:\Users\archeon1\python\python-3.12.4-embed-amd64\python.exe C:\Users\archeon1\OneDrive\_Inv\INVENTORY20240505(Gitd_20240702)\INVENTORY\_\_ops.py
import csv
import os
def func1():
    arrRpts = os.listdir('PC')
    for i in range(len(arrRpts)):
        filename = arrRpts[i]
        with open(filename, 'r') as file:
            reader = csv.reader(file)
            header = next(reader)
            print(f"{header}")
            for row in reader:
                print("|",row)
                
func1()
