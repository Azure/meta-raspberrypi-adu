#!/usr/bin/env python3
"""Delta Update Operations Tool"""

import os
import sys
import hashlib
import argparse

def calculate_hash(filepath, algorithm="sha256"):
    """Calculate hash of a file"""
    hash_func = hashlib.new(algorithm)
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            hash_func.update(chunk)
    return hash_func.hexdigest()

def verify_files(file1, file2):
    """Verify two files are identical"""
    print(f"Verifying: {file1} == {file2}")
    hash1 = calculate_hash(file1)
    hash2 = calculate_hash(file2)
    
    if hash1 == hash2:
        print(f"✓ Files match (SHA256: {hash1})")
        return True
    else:
        print(f"✗ Files differ")
        print(f"  {file1}: {hash1}")
        print(f"  {file2}: {hash2}")
        return False

def show_file_info(filepath):
    """Show file information"""
    size = os.path.getsize(filepath)
    hash_val = calculate_hash(filepath)
    print(f"File: {filepath}")
    print(f"  Size: {size:,} bytes ({size/1024/1024:.2f} MB)")
    print(f"  SHA256: {hash_val}")

def main():
    parser = argparse.ArgumentParser(description="Delta Update Operations")
    parser.add_argument("command", choices=["hash", "verify", "info"])
    parser.add_argument("files", nargs="+", help="File path(s)")
    
    args = parser.parse_args()
    
    if args.command == "hash":
        for f in args.files:
            print(f"{calculate_hash(f)}  {f}")
    elif args.command == "verify":
        if len(args.files) != 2:
            print("Error: verify requires exactly 2 files")
            return 1
        return 0 if verify_files(args.files[0], args.files[1]) else 1
    elif args.command == "info":
        for f in args.files:
            show_file_info(f)
            print()
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
