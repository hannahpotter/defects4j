import os

# https://stackoverflow.com/questions/38834378/path-to-a-directory-as-argparse-argument
def dir_path(string):
    if os.path.isdir(string):
        return string
    else:
        raise NotADirectoryError(string)
    
def file_path(string):
    dir = os.path.dirname(string)
    if os.path.isdir(dir):
        return string
    else:
        raise NotADirectoryError(string)
    
# From Google AI Overview example for "get all files in folder and subfolders python"
def get_all_files(directory, extension = None):
    file_list = []
    for root, dirs, files in os.walk(directory):
        for file in files:
            if extension is None or os.path.splitext(file)[1] == extension:
                file_list.append(os.path.join(root, file))
    return file_list