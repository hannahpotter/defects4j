import argparse
from path_utils import *
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--dependency', type=file_path)
parser.add_argument('--classes', type=dir_path)
parser.add_argument('--testclasses', type=dir_path)
parser.add_argument('--reports', type=dir_path)
parser.add_argument('--output', type=dir_path)
args = parser.parse_args()

reports = get_all_files(args.reports, extension = ".xml")

testcases = open(os.path.join(args.output, "testcases.txt"), "w")
testsuites = open(os.path.join(args.output, "testsuites.txt"), "w")
removed = open(os.path.join(args.output, "removed.txt"), "w")
testsuite_names = []
# https://www.geeksforgeeks.org/xml-parsing-python/
for file in reports:
    root = ET.parse(file).getroot()
    # Record test suites
    if root.tag == "testsuite":
        testsuites.write(root.get("name") + "\n")
        testsuite_names.append(root.get("name"))
    else:
        for testsuite in root.findall("testsuite"):
            testsuites.write(testsuite.get("name") + "\n")
            testsuite_names.append(root.get("name"))
    # Record test cases
    # Format: <test_class>#<test_method>
    for testcase in root.findall("testcase"):
        # If the testcase element has a child element, the test failed, had an error, or was skipped
        if len(testcase):
            removed.write(" ---------- " + testcase.get("classname") + "#" + testcase.get("name") + " ----------\n")
            for child in testcase:
                removed.write(ET.tostring(child, encoding="unicode") + "\n")
        else:
            testcases.write(testcase.get("classname") + "#" + testcase.get("name") + "\n")

testcases.close()
testsuites.close()

f = open(args.dependency, "r")
dependency_path = f.readline()
dependency_path = "" if not dependency_path else ":" + dependency_path
f.close()

classpath = args.testclasses + ":" + args.classes + dependency_path
args_file = open(os.path.join(args.output, "args_junit.txt"), "w")
args_file.write("--classpath " + classpath + "\n")
args_file.close()

version = open(os.path.join(args.output, "version.txt"), "w")
for dependency in dependency_path.split(":"):
    if "junit" in dependency:
        v = dependency.split("/")[3]
        v = v.split(".")[0]
        version.write(v)
version.close()