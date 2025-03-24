import argparse
import os

parser = argparse.ArgumentParser()
parser.add_argument('--analyzer')

args = parser.parse_args()


source_classpaths = set()
test_classpaths = set()
for root, dirs, files in os.walk(args.analyzer):
    for file in files:
        if os.path.basename(file) == "source_cp":
            source_cp = open(os.path.join(root, file), "r")
            source_classpaths.add(source_cp.readline())
            source_cp.close()
        if os.path.basename(file) == "test_cp":
            test_cp = open(os.path.join(root, file), "r")
            test_classpaths.add(test_cp.readline())
            test_cp.close()

print("Number of distinct source classpaths: " + str(len(source_classpaths)))
print("Number of distinct test classpaths: " + str(len(test_classpaths)))
