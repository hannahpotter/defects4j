import argparse
import os

parser = argparse.ArgumentParser()
parser.add_argument('--argsfiles')

args = parser.parse_args()


source_classpaths = set()
test_classpaths = set()
for root, dirs, files in os.walk(args.argsfiles):
    for file in files:
        if os.path.basename(file) == "args_source_v1.txt":
            source_cp = open(os.path.join(root, file), "r")
            source_classpaths.add("\n".join(source_cp.readlines()))
            source_cp.close()
        if os.path.basename(file) == "args_source_v2.txt":
            source_cp = open(os.path.join(root, file), "r")
            source_classpaths.add("\n".join(source_cp.readlines()))
            source_cp.close()
        if os.path.basename(file) == "args_test_v2.txt":
            test_cp = open(os.path.join(root, file), "r")
            test_classpaths.add("\n".join(test_cp.readlines()))
            test_cp.close()

print("Number of distinct source arg files: " + str(len(source_classpaths)))
print("Number of distinct test arg files: " + str(len(test_classpaths)))
