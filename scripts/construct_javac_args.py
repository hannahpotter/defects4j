import argparse
from path_utils import *
    
parser = argparse.ArgumentParser()
parser.add_argument('--dependency', type=file_path)
parser.add_argument('--projectpath', type=dir_path)
parser.add_argument('--classpath')
parser.add_argument('--target')
parser.add_argument('--sourcepath')
parser.add_argument('--sourcefiles', type=dir_path)
parser.add_argument('--output', type=file_path)
args = parser.parse_args()

f = open(args.dependency, "r")
dependency_path = f.readline()
dependency_path = "" if not dependency_path else ":" + dependency_path
f.close()
files = get_all_files(args.sourcefiles)
src_path = []
for path in files:
    src_path.append(path.replace(args.projectpath + "/", ""))

# construct arguments
#-classpath classpath:<jars>
#-sourcepath src/main/java
#-d target/classes
#<java files>
classpath = args.classpath + dependency_path
sources = "\n".join(src_path)

f = open(args.output, "w")
f.write("-classpath " + classpath + "\n")
f.write("-sourcepath " + args.sourcepath + "\n")
f.write("-d " + args.target + "\n")
f.write(sources)
f.close()
