# FreeSurfer Longitudinal Pipeline for HPC

This repository provides an automated batching and job-submission pipeline for processing longitudinal MRI data using FreeSurfer on SLURM-managed high-performance computing (HPC) clusters.

The pipeline is designed to handle multiple timepoints per subject (e.g., baseline, 2-year follow-up), and runs the following stages in order:

1. Raw recon-all processing  
2. Base creation for each subject  
3. Longitudinal recon-all processing  
4. Segmentation (e.g., hippocampus and amygdala)

---

## Features

- Parses and groups NIfTI files by NDAR subject ID
- Batches subjects (e.g., 3 per batch) to limit memory usage
- Generates task files for each processing stage
- Creates SLURM job scripts using the TACC Launcher module
- Submits jobs with correct dependencies (`afterok`) to enforce order
- Includes a master script to run all batch pipelines sequentially

---

## Requirements

- FreeSurfer 8.0.0 (or compatible)
- SLURM
- TACC Launcher (e.g., module `launcher/3.9`)
- Bash shell

---

## Configuration Variables (in `FreeSurfer_Pipeline_HPC.sh`)

- `FREESURFER_INIT`: Path to FreeSurfer's `initialize_env.sh`
- `CORES_PER_NODE`: Number of cores per compute node (e.g., 64)
- `TIME_LIMIT`: Wall time for each SLURM job (e.g., `48:00:00`)
- `LAUNCHER_MODULE`: The SLURM launcher module to load (e.g., `launcher/3.9`)
- `batch_size`: Number of subjects per batch. Default is 3 for memory safety

---

## How to Use

1. Place all `.nii` or `.nii.gz` files in the same directory as `FreeSurfer_Pipeline_HPC.sh`.

2. Run the pipeline script:

   ```bash
   bash FreeSurfer_Pipeline_HPC.sh
