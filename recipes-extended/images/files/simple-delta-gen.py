#!/usr/bin/env python3
"""
Simple Delta Generator - Native Python replacement for DiffGenTool
This is a lightweight wrapper that orchestrates the delta generation
without requiring .NET runtime or cross-architecture native binaries.

Architecture: Uses host-native tools (bsdiff, zstd) instead of target binaries.
"""

import os
import sys
import subprocess
import tempfile
import shutil
import tarfile
import gzip
from pathlib import Path


class SimpleDeltaGen:
    """Simplified delta generator for SWU update files"""
    
    def __init__(self, source_swu, target_swu, output_diff, log_dir, work_dir, recompressed_output=None):
        self.source_swu = Path(source_swu)
        self.target_swu = Path(target_swu)
        self.output_diff = Path(output_diff)
        self.log_dir = Path(log_dir)
        self.work_dir = Path(work_dir)
        self.recompressed_output = Path(recompressed_output) if recompressed_output else None
        
        # Create directories
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.work_dir.mkdir(parents=True, exist_ok=True)
        
        self.source_dir = self.work_dir / "source"
        self.target_dir = self.work_dir / "target"
        self.source_dir.mkdir(exist_ok=True)
        self.target_dir.mkdir(exist_ok=True)
    
    def log(self, message):
        """Log to console and file"""
        print(f"[SimpleDeltaGen] {message}")
        log_file = self.log_dir / "delta-generation.log"
        with open(log_file, 'a') as f:
            f.write(f"{message}\n")
    
    def run_command(self, cmd, description):
        """Run a shell command with logging"""
        self.log(f"Running: {description}")
        self.log(f"Command: {' '.join(cmd)}")
        
        try:
            result = subprocess.run(
                cmd,
                check=True,
                capture_output=True,
                text=True
            )
            if result.stdout:
                self.log(f"Output: {result.stdout}")
            return True
        except subprocess.CalledProcessError as e:
            self.log(f"ERROR: Command failed with code {e.returncode}")
            self.log(f"STDERR: {e.stderr}")
            return False
    
    def extract_swu(self, swu_file, extract_dir):
        """Extract SWU file (CPIO archive) and return original file order
        
        Returns:
            list: Original file order from the CPIO archive, or None on failure
        """
        self.log(f"Extracting {swu_file.name} to {extract_dir}")
        
        # First, get the original file order from the CPIO archive
        file_order = []
        try:
            with open(swu_file, 'rb') as f:
                result = subprocess.run(
                    ['cpio', '-it'],
                    stdin=f,
                    capture_output=True,
                    text=True,
                    check=True
                )
                # Parse file list (one file per line)
                file_order = [line.strip() for line in result.stdout.splitlines() if line.strip()]
                self.log(f"Original file order ({len(file_order)} files):")
                for i, fname in enumerate(file_order[:10], 1):  # Show first 10
                    self.log(f"  {i}. {fname}")
                if len(file_order) > 10:
                    self.log(f"  ... and {len(file_order) - 10} more files")
        except subprocess.CalledProcessError as e:
            self.log(f"WARNING: Failed to list files from {swu_file.name}: {e}")
            # Continue with extraction even if listing failed
        
        # Now extract the files
        cmd = ['cpio', '-idmv']
        try:
            with open(swu_file, 'rb') as f:
                result = subprocess.run(
                    cmd,
                    stdin=f,
                    cwd=extract_dir,
                    check=True,
                    capture_output=True
                )
            self.log(f"Extracted {swu_file.name} successfully")
            return file_order if file_order else None
        except subprocess.CalledProcessError as e:
            self.log(f"Failed to extract {swu_file.name}: {e}")
            return None
    
    def find_rootfs_images(self, extract_dir):
        """Find the main rootfs images in extracted SWU"""
        # Look for .ext4, .ext4.gz, or similar filesystem images
        patterns = ['*.ext4', '*.ext4.gz', '*.img', '*.img.gz']
        images = []
        for pattern in patterns:
            images.extend(extract_dir.glob(pattern))
        
        if images:
            self.log(f"Found rootfs images: {[str(img.name) for img in images]}")
            return sorted(images)  # Return largest/first
        
        self.log("WARNING: No rootfs images found, will diff entire SWU contents")
        return []
    
    def create_bsdiff(self, source_file, target_file, diff_file):
        """Create binary diff using bsdiff"""
        self.log(f"Creating bsdiff: {source_file.name} -> {target_file.name}")
        
        # Check if bsdiff is available
        if not shutil.which('bsdiff'):
            self.log("ERROR: bsdiff not found in PATH")
            return False
        
        cmd = ['bsdiff', str(source_file), str(target_file), str(diff_file)]
        return self.run_command(cmd, "Binary diff with bsdiff")
    
    def compress_with_zstd(self, input_file, output_file, level=3):
        """Compress file with zstd"""
        self.log(f"Compressing {input_file.name} with zstd")
        
        if not shutil.which('zstd'):
            self.log("WARNING: zstd not found, using gzip")
            return self.compress_with_gzip(input_file, output_file)
        
        cmd = ['zstd', '-f', f'-{level}', str(input_file), '-o', str(output_file)]
        return self.run_command(cmd, "Compress with zstd")
    
    def compress_with_gzip(self, input_file, output_file):
        """Fallback: Compress with gzip"""
        self.log(f"Compressing {input_file.name} with gzip")
        
        with open(input_file, 'rb') as f_in:
            with gzip.open(output_file, 'wb', compresslevel=6) as f_out:
                shutil.copyfileobj(f_in, f_out)
        return True
    
    def recompress_swu(self, original_swu, output_swu):
        """Recompress SWU file for deterministic delta generation
        
        Extracts and recreates the CPIO archive preserving the EXACT file order.
        This ensures the reconstructed .swu from delta will have matching hash.
        """
        self.log("=" * 60)
        self.log(f"Recompressing SWU: {original_swu.name}")
        self.log(f"Output: {output_swu}")
        self.log("=" * 60)
        
        # Get original size before any operations (file may be cleaned up later)
        try:
            original_size = original_swu.stat().st_size
        except OSError:
            original_size = 0
            self.log("WARNING: Could not stat original file (may have been cleaned)")
        
        # Extract to temp directory and get original file order
        temp_extract = self.work_dir / f"recompress_{original_swu.stem}"
        temp_extract.mkdir(exist_ok=True)
        
        original_file_order = self.extract_swu(original_swu, temp_extract)
        if original_file_order is None:
            self.log("ERROR: Failed to extract SWU")
            return False
        
        # Verify sw-description is first (SWUpdate requirement)
        if not original_file_order or original_file_order[0] != "sw-description":
            self.log("WARNING: sw-description is not first in original file order!")
            self.log("This may indicate an invalid SWU file.")
            # Still try to proceed, but enforce sw-description first
            if "sw-description" in original_file_order:
                original_file_order.remove("sw-description")
            original_file_order.insert(0, "sw-description")
        
        # Verify all files from the list actually exist
        file_list = []
        for fname in original_file_order:
            fpath = temp_extract / fname
            if fpath.is_file():
                file_list.append(fname)
            else:
                self.log(f"WARNING: File {fname} from CPIO listing not found on disk, skipping")
        
        if not file_list:
            self.log("ERROR: No files to recompress!")
            return False
        
        self.log(f"Recompressing with ORIGINAL file order ({len(file_list)} files):")
        for i, fname in enumerate(file_list[:10], 1):  # Show first 10
            self.log(f"  {i}. {fname}")
        if len(file_list) > 10:
            self.log(f"  ... and {len(file_list) - 10} more files")
        
        # Recreate CPIO archive with EXACT original file order
        self.log("Creating recompressed CPIO archive with original file order...")
        try:
            # Create CPIO archive using explicit file list (maintains order)
            # Format: echo file1; echo file2; ... | cpio -o -H crc --reproducible
            # --reproducible: Sets consistent timestamps and ordering for deterministic output
            with subprocess.Popen(
                ['sh', '-c', 'while IFS= read -r file; do echo "$file"; done | cpio -o -H crc --reproducible'],
                cwd=temp_extract,
                stdin=subprocess.PIPE,
                stdout=open(output_swu, 'wb'),
                stderr=subprocess.PIPE,
                text=True
            ) as cpio_proc:
                # Send file list to stdin (one per line)
                file_list_str = '\n'.join(file_list) + '\n'
                stdout, stderr = cpio_proc.communicate(input=file_list_str)
                
                if cpio_proc.returncode != 0:
                    self.log(f"ERROR: CPIO failed: {stderr}")
                    return False
            
            recompressed_size = output_swu.stat().st_size
            self.log(f"Original size: {original_size:,} bytes")
            self.log(f"Recompressed size: {recompressed_size:,} bytes")
            if original_size > 0:
                self.log(f"Size difference: {recompressed_size - original_size:+,} bytes")
            self.log("Recompression completed successfully!")
            
            # Cleanup temp extraction
            shutil.rmtree(temp_extract, ignore_errors=True)
            
            return True
            
        except Exception as e:
            self.log(f"ERROR during recompression: {e}")
            shutil.rmtree(temp_extract, ignore_errors=True)
            return False
    
    def generate_delta(self):
        """Main delta generation workflow - diff SWU files directly"""
        self.log("=" * 60)
        self.log("Starting SWU-to-SWU Delta Generation")
        self.log(f"Source: {self.source_swu}")
        self.log(f"Target: {self.target_swu}")
        self.log(f"Output Delta: {self.output_diff}")
        if self.recompressed_output:
            self.log(f"Output Recompressed: {self.recompressed_output}")
        self.log("=" * 60)
        
        # Get source and target sizes
        source_size = self.source_swu.stat().st_size
        target_size = self.target_swu.stat().st_size
        self.log(f"Source SWU size: {source_size:,} bytes ({source_size/1024/1024:.2f} MB)")
        self.log(f"Target SWU size: {target_size:,} bytes ({target_size/1024/1024:.2f} MB)")
        self.log("")
        
        # Recompress target SWU for deterministic delta
        if self.recompressed_output:
            self.log("Step 1: Recompressing target SWU for deterministic delta...")
            if not self.recompress_swu(self.target_swu, self.recompressed_output):
                self.log("WARNING: Recompression failed, using original target")
                target_for_diff = self.target_swu
            else:
                target_for_diff = self.recompressed_output
                self.log("Using recompressed target for delta generation")
        else:
            target_for_diff = self.target_swu
            self.log("No recompression requested, using original target")
        
        self.log("")
        
        # Create binary diff directly between SWU files
        self.log("Step 2: Creating binary diff between SWU files...")
        self.log("This approach diffs the complete .swu files (compressed archives)")
        self.log("which are smaller and faster than extracting/diffing internal images.")
        self.log("This may take several minutes...")
        self.log("")
        
        temp_diff = self.work_dir / "swu.diff"
        if not self.create_bsdiff(self.source_swu, target_for_diff, temp_diff):
            return False
        
        # Compress the delta with zstd for additional space savings
        self.log("Step 3: Compressing diff file...")
        if not self.compress_with_zstd(temp_diff, self.output_diff):
            return False
        
        # Generate statistics
        self.log("Step 4: Generating statistics...")
        if self.recompressed_output and self.recompressed_output.exists():
            self.generate_statistics(self.source_swu, self.recompressed_output, self.output_diff)
        else:
            self.generate_statistics(self.source_swu, self.target_swu, self.output_diff)
        
        self.log("=" * 60)
        self.log("Delta generation completed successfully!")
        self.log(f"Delta file: {self.output_diff}")
        if self.recompressed_output:
            self.log(f"Recompressed target: {self.recompressed_output}")
        self.log("=" * 60)
        
        return True
    
    def generate_statistics(self, source_file, target_file, diff_file):
        """Generate delta statistics"""
        source_size = source_file.stat().st_size
        target_size = target_file.stat().st_size
        diff_size = diff_file.stat().st_size
        
        compression_ratio = (diff_size / target_size) * 100 if target_size > 0 else 0
        
        stats_file = self.log_dir / "statistics.txt"
        with open(stats_file, 'w') as f:
            f.write(f"Delta Generation Statistics\n")
            f.write(f"===========================\n\n")
            f.write(f"Source size: {source_size:,} bytes ({source_size/1024/1024:.2f} MB)\n")
            f.write(f"Target size: {target_size:,} bytes ({target_size/1024/1024:.2f} MB)\n")
            f.write(f"Delta size:  {diff_size:,} bytes ({diff_size/1024/1024:.2f} MB)\n")
            f.write(f"Compression: {compression_ratio:.2f}% of target\n")
            f.write(f"Space saved: {target_size - diff_size:,} bytes\n")
        
        self.log(f"Statistics written to {stats_file}")


def main():
    if len(sys.argv) not in [6, 7]:
        print("Usage: simple-delta-gen.py <source.swu> <target.swu> <output.diff> <log_dir> <work_dir> [recompressed.swu]")
        print("  recompressed.swu: Optional - if provided, target will be recompressed to this file")
        sys.exit(1)
    
    recompressed = sys.argv[6] if len(sys.argv) == 7 else None
    
    generator = SimpleDeltaGen(
        source_swu=sys.argv[1],
        target_swu=sys.argv[2],
        output_diff=sys.argv[3],
        log_dir=sys.argv[4],
        work_dir=sys.argv[5],
        recompressed_output=recompressed
    )
    
    success = generator.generate_delta()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
