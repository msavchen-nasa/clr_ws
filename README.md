# CLR Demonstration Workspace

This workspace is a fork of [clr_ws](https://github.com/NASA-JSC-Robotics/clr_ws), that focuses on development and testing of VLA models with the iMETRO facility.

For more information about iMETRO visit [here](https://github.com/NASA-JSC-Robotics/iMETRO).

Changes to this workspace include: 
* Addition of several submodules
* Different configuration for initial robot arm positions
* Different configuration for initial CTB position.
* Additional MuJoCo scene cameras.

## Quick Instructions for Giovanni
1) Make sure that `git-lfs` is installed.
2) Clone this repository and remember to include the submodules
    ```bash
    # Clone with submodules
    git clone --recursive https://github.com/msavchen-nasa/clr_ws.git
    ```
    or if you already cloned without recursive
    ```bash
    # Or initialize them from the repo's root
    cd clr_ws
    git submodule update --init
    ```
3) LeRobot-Mujoco package will already be included inside `src/vla` directory. 

## Citation

This project falls under the purview of the iMETRO project.
If you use this in your own work, please cite the following paper:

```bibtex
@INPROCEEDINGS{imetro-facility-2025,
  author={Dunkelberger, Nathan and Sheetz, Emily and Rainen, Connor and Graf, Jodi and Hart, Nikki and Zemler, Emma and Azimi, Shaun},
  booktitle={2025 22nd International Conference on Ubiquitous Robots (UR)},
  title={Design of the iMETRO Facility: A Platform for Intravehicular Space Robotics Research},
  year={2025},
  volume={},
  number={},
  pages={390-397},
  keywords={NASA;Moon;Seals;Maintenance engineering;Maintenance;Robots;Standards;Open source software;Testing;Logistics},
  doi={10.1109/UR65550.2025.11077983}}
```
