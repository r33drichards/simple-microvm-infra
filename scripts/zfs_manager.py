#!/usr/bin/env python3
"""
ZFS Manager - Provides a Python interface to ZFS operations.

Uses libzfs_core (pyzfs) when available for better performance and error handling,
falls back to CLI when not available.
"""

import subprocess
import logging
from typing import List, Optional, Dict
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass
class ZFSSnapshot:
    """Represents a ZFS snapshot."""
    pool: str
    dataset: str
    name: str

    @property
    def full_name(self) -> str:
        """Returns the full snapshot name (pool/dataset@name)."""
        return f"{self.pool}/{self.dataset}@{self.name}"


@dataclass
class ZFSDataset:
    """Represents a ZFS dataset."""
    pool: str
    path: str

    @property
    def full_name(self) -> str:
        """Returns the full dataset name (pool/path)."""
        return f"{self.pool}/{self.path}"


class ZFSManager:
    """
    Manages ZFS operations using libzfs_core or CLI fallback.
    
    This class provides a consistent interface for ZFS operations,
    using the native library when available for better performance.
    """

    def __init__(self, pool: str, base_dataset: str):
        """
        Initialize ZFS manager.
        
        Args:
            pool: ZFS pool name (e.g., "microvms")
            base_dataset: Base dataset path (e.g., "storage/states")
        """
        self.pool = pool
        self.base_dataset = base_dataset
        self.use_native = False

        # Try to import libzfs_core
        try:
            import libzfs_core as lzc
            self.lzc = lzc
            self.use_native = True
            logger.info("Using native libzfs_core for ZFS operations")
        except ImportError:
            logger.info("libzfs_core not available, using CLI fallback")
            self.lzc = None

    def _run_command(self, cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
        """Run a shell command and return result."""
        logger.debug(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            logger.error(f"Command failed: {result.stderr}")
            if check:
                raise subprocess.CalledProcessError(
                    result.returncode, cmd, result.stdout, result.stderr
                )
        return result

    def dataset_exists(self, dataset_name: str) -> bool:
        """
        Check if a dataset exists.
        
        Args:
            dataset_name: Name of the dataset (relative to base_dataset)
            
        Returns:
            True if dataset exists, False otherwise
        """
        full_name = f"{self.pool}/{self.base_dataset}/{dataset_name}"

        if self.use_native:
            try:
                # libzfs_core doesn't have a direct exists check, 
                # but we can try to get properties
                self.lzc.lzc_get_props(full_name)
                return True
            except Exception:
                return False
        else:
            result = self._run_command(
                ["zfs", "list", "-H", full_name],
                check=False
            )
            return result.returncode == 0

    def snapshot_exists(self, snapshot_name: str) -> bool:
        """
        Check if a snapshot exists with the given name.
        
        Args:
            snapshot_name: Snapshot name (without @ prefix)
            
        Returns:
            True if snapshot exists, False otherwise
        """
        if self.use_native:
            # List all snapshots and check if any match
            try:
                snapshots = self.list_snapshots()
                return any(s.name == snapshot_name for s in snapshots)
            except Exception:
                return False
        else:
            result = self._run_command([
                "zfs", "list", "-H", "-t", "snapshot", "-o", "name",
                "-r", f"{self.pool}/{self.base_dataset}"
            ], check=False)

            if result.returncode != 0:
                return False

            for line in result.stdout.strip().split('\n'):
                if line.endswith(f"@{snapshot_name}"):
                    return True
            return False

    def list_snapshots(self) -> List[ZFSSnapshot]:
        """
        List all snapshots under the base dataset.
        
        Returns:
            List of ZFSSnapshot objects
        """
        snapshots = []

        if self.use_native:
            # libzfs_core doesn't have a direct list snapshots API
            # Fall back to CLI for this operation
            pass

        # Use CLI (works for both native and fallback)
        result = self._run_command([
            "zfs", "list", "-H", "-t", "snapshot", "-o", "name",
            "-r", f"{self.pool}/{self.base_dataset}"
        ])

        for line in result.stdout.strip().split('\n'):
            if not line:
                continue
            # Parse pool/dataset@snapshot
            parts = line.split('@')
            if len(parts) == 2:
                dataset_parts = parts[0].split('/')
                pool = dataset_parts[0]
                dataset = '/'.join(dataset_parts[1:])
                snapshot = ZFSSnapshot(pool=pool, dataset=dataset, name=parts[1])
                snapshots.append(snapshot)

        return snapshots

    def find_snapshot(self, snapshot_name: str) -> Optional[ZFSSnapshot]:
        """
        Find a snapshot by name.
        
        Args:
            snapshot_name: Name of the snapshot (without @ prefix)
            
        Returns:
            ZFSSnapshot object if found, None otherwise
        """
        snapshots = self.list_snapshots()
        for snapshot in snapshots:
            if snapshot.name == snapshot_name:
                return snapshot
        return None

    def create_dataset(self, dataset_name: str, mountpoint: str) -> None:
        """
        Create a new ZFS dataset.
        
        Args:
            dataset_name: Name of the dataset (relative to base_dataset)
            mountpoint: Mount point for the dataset
        """
        full_name = f"{self.pool}/{self.base_dataset}/{dataset_name}"

        if self.use_native:
            try:
                # Create dataset with mountpoint property
                props = {b"mountpoint": mountpoint.encode()}
                self.lzc.lzc_create(full_name.encode(), ds_type='zfs', props=props)
                logger.info(f"Created dataset {full_name} (native)")
                return
            except Exception as e:
                logger.warning(f"Native create failed, falling back to CLI: {e}")

        # CLI fallback
        self._run_command([
            "zfs", "create",
            "-o", f"mountpoint={mountpoint}",
            full_name
        ])
        logger.info(f"Created dataset {full_name} (CLI)")

    def create_snapshot(self, dataset_name: str, snapshot_name: str) -> None:
        """
        Create a ZFS snapshot.
        
        Args:
            dataset_name: Name of the dataset (relative to base_dataset)
            snapshot_name: Name for the snapshot
        """
        full_dataset = f"{self.pool}/{self.base_dataset}/{dataset_name}"
        full_snapshot = f"{full_dataset}@{snapshot_name}"

        if self.use_native:
            try:
                self.lzc.lzc_snapshot([full_snapshot.encode()])
                logger.info(f"Created snapshot {full_snapshot} (native)")
                return
            except Exception as e:
                logger.warning(f"Native snapshot failed, falling back to CLI: {e}")

        # CLI fallback
        self._run_command(["zfs", "snapshot", full_snapshot])
        logger.info(f"Created snapshot {full_snapshot} (CLI)")

    def clone_snapshot(
        self, 
        snapshot: ZFSSnapshot, 
        new_dataset_name: str, 
        mountpoint: str
    ) -> None:
        """
        Clone a snapshot to a new dataset.
        
        Args:
            snapshot: ZFSSnapshot object to clone
            new_dataset_name: Name for the new dataset (relative to base_dataset)
            mountpoint: Mount point for the new dataset
        """
        new_dataset = f"{self.pool}/{self.base_dataset}/{new_dataset_name}"

        if self.use_native:
            try:
                props = {b"mountpoint": mountpoint.encode()}
                self.lzc.lzc_clone(
                    new_dataset.encode(),
                    snapshot.full_name.encode(),
                    props=props
                )
                logger.info(f"Cloned {snapshot.full_name} to {new_dataset} (native)")
                return
            except Exception as e:
                logger.warning(f"Native clone failed, falling back to CLI: {e}")

        # CLI fallback
        self._run_command([
            "zfs", "clone",
            "-o", f"mountpoint={mountpoint}",
            snapshot.full_name, new_dataset
        ])
        logger.info(f"Cloned {snapshot.full_name} to {new_dataset} (CLI)")

    def promote_dataset(self, dataset_name: str) -> None:
        """
        Promote a cloned dataset to be independent.
        
        Args:
            dataset_name: Name of the dataset (relative to base_dataset)
        """
        full_name = f"{self.pool}/{self.base_dataset}/{dataset_name}"

        if self.use_native:
            try:
                self.lzc.lzc_promote(full_name.encode())
                logger.info(f"Promoted dataset {full_name} (native)")
                return
            except Exception as e:
                logger.warning(f"Native promote failed, falling back to CLI: {e}")

        # CLI fallback
        self._run_command(["zfs", "promote", full_name])
        logger.info(f"Promoted dataset {full_name} (CLI)")

    def destroy_dataset(self, dataset_name: str, recursive: bool = False) -> None:
        """
        Destroy a ZFS dataset.
        
        Args:
            dataset_name: Name of the dataset (relative to base_dataset)
            recursive: If True, destroy all descendants
        """
        full_name = f"{self.pool}/{self.base_dataset}/{dataset_name}"

        if self.use_native:
            try:
                self.lzc.lzc_destroy(full_name.encode())
                logger.info(f"Destroyed dataset {full_name} (native)")
                return
            except Exception as e:
                logger.warning(f"Native destroy failed, falling back to CLI: {e}")

        # CLI fallback
        cmd = ["zfs", "destroy"]
        if recursive:
            cmd.append("-r")
        cmd.append(full_name)
        self._run_command(cmd)
        logger.info(f"Destroyed dataset {full_name} (CLI)")
