# ============================================================================
# Makefile for VPU RTL Testbench Simulation
# ============================================================================
# 
# Usage:
#   make tb_pmau          - Run PMAU_Full testbench
#   make tb_vpu           - Run VPU_Top testbench
#   make all              - Run all testbenches
#   make clean            - Remove simulation artifacts
#   make help             - Show this help message
#
# Environment variables:
#   VIVADO_PATH    - Path to Vivado installation (default: /opt/xilinx/Vivado/2023.2)
#   TB_DIR         - Testbench directory (default: current directory)
#   RTL_DIR        - RTL directory (default: ../RTL)
#   SIM_DIR        - Simulation work directory (default: ./sim)
#   VERBOSITY      - Simulation verbosity (0=normal, 1=verbose, 2=debug)
#
# ============================================================================

# Default variables
VIVADO_PATH ?= /opt/xilinx/Vivado/2023.2
TB_DIR := .
RTL_DIR := ../RTL
SIM_DIR := ./sim
LOG_DIR := ./logs
WAVE_DIR := ./waveforms
VERBOSITY ?= 0

# Vivado tool paths
XVLOG := $(VIVADO_PATH)/bin/xvlog
XELAB := $(VIVADO_PATH)/bin/xelab
XSIM := $(VIVADO_PATH)/bin/xsim
WORK := xsim_work

# RTL and TB files
PMAU_Full_RTL := $(RTL_DIR)/PMAU_Full.v
VPU_TOP_RTL := $(RTL_DIR)/VPU_Top.v
TB_PMAU := $(TB_DIR)/tb_PMAU_Full.v
TB_VPU := $(TB_DIR)/tb_VPU_Top.v

# Testbench names
TB_PMAU_NAME := tb_PMAU_Full
TB_VPU_NAME := tb_VPU_Top

# ============================================================================
# Phony targets (not file-based)
# ============================================================================

.PHONY: help all tb_pmau tb_vpu clean clean_logs clean_waves setup

# ============================================================================
# Help target
# ============================================================================

help:
	@echo "VPU RTL Testbench Makefile"
	@echo "============================================================================"
	@echo "Targets:"
	@echo "  make help          - Show this help message"
	@echo "  make setup         - Create simulation directories"
	@echo "  make tb_pmau       - Run PMAU_Full testbench"
	@echo "  make tb_vpu        - Run VPU_Top testbench"
	@echo "  make all           - Run all testbenches"
	@echo "  make clean         - Remove all simulation artifacts"
	@echo "  make clean_logs    - Remove log files only"
	@echo "  make clean_waves   - Remove waveform files only"
	@echo ""
	@echo "Variables:"
	@echo "  VIVADO_PATH        Current: $(VIVADO_PATH)"
	@echo "  RTL_DIR            Current: $(RTL_DIR)"
	@echo "  VERBOSITY          Current: $(VERBOSITY) (0=normal, 1=verbose, 2=debug)"
	@echo ""
	@echo "Examples:"
	@echo "  make tb_pmau VERBOSITY=2"
	@echo "  make tb_vpu VIVADO_PATH=/tools/xilinx/Vivado/2024.1"
	@echo "============================================================================"

# ============================================================================
# Setup directories
# ============================================================================

setup:
	@echo "[SETUP] Creating simulation directories..."
	@mkdir -p $(SIM_DIR) $(LOG_DIR) $(WAVE_DIR)
	@echo "[SETUP] Done."

# ============================================================================
# PMAU_Full Testbench
# ============================================================================

tb_pmau: setup
	@echo ""
	@echo "============================================================================"
	@echo "Running PMAU_Full Testbench"
	@echo "============================================================================"
	@echo "[COMPILE] Compiling RTL sources..."
	@cd $(SIM_DIR) && $(XVLOG) -work $(WORK) \
		$(abspath $(PMAU_Full_RTL)) \
		$(abspath $(VPU_TOP_RTL)) \
		2>&1 | tee -a $(abspath $(LOG_DIR))/pmau_compile.log
	@if [ $$? -ne 0 ]; then echo "[ERROR] Compilation failed!"; exit 1; fi
	
	@echo "[COMPILE] Compiling testbench..."
	@cd $(SIM_DIR) && $(XVLOG) -work $(WORK) \
		$(abspath $(TB_PMAU)) \
		2>&1 | tee -a $(abspath $(LOG_DIR))/pmau_compile.log
	@if [ $$? -ne 0 ]; then echo "[ERROR] Testbench compilation failed!"; exit 1; fi
	
	@echo "[ELAB] Elaborating design..."
	@cd $(SIM_DIR) && $(XELAB) -work $(WORK) \
		-top $(TB_PMAU_NAME) \
		-debug $(TB_PMAU_NAME) \
		2>&1 | tee -a $(abspath $(LOG_DIR))/pmau_elab.log
	@if [ $$? -ne 0 ]; then echo "[ERROR] Elaboration failed!"; exit 1; fi
	
	@echo "[SIM] Running simulation..."
	@cd $(SIM_DIR) && $(XSIM) -work $(WORK) \
		$(TB_PMAU_NAME) \
		-log $(abspath $(LOG_DIR))/pmau_simulation.log \
		2>&1 | tee -a $(abspath $(LOG_DIR))/pmau_simulation.log
	@echo ""
	@echo "[RESULTS]"
	@grep -E "\[PASS\]|\[FAIL\]|Final Results" $(LOG_DIR)/pmau_simulation.log || true

# ============================================================================
# VPU_Top Testbench
# ============================================================================

tb_vpu: setup
	@echo ""
	@echo "============================================================================"
	@echo "Running VPU_Top Testbench"
	@echo "============================================================================"
	@echo "[COMPILE] Compiling RTL sources..."
	@cd $(SIM_DIR) && $(XVLOG) -work $(WORK) \
		$(abspath $(PMAU_Full_RTL)) \
		$(abspath $(VPU_TOP_RTL)) \
		2>&1 | tee -a $(abspath $(LOG_DIR))/vpu_compile.log
	@if [ $$? -ne 0 ]; then echo "[ERROR] Compilation failed!"; exit 1; fi
	
	@echo "[COMPILE] Compiling testbench..."
	@cd $(SIM_DIR) && $(XVLOG) -work $(WORK) \
		$(abspath $(TB_VPU)) \
		2>&1 | tee -a $(abspath $(LOG_DIR))/vpu_compile.log
	@if [ $$? -ne 0 ]; then echo "[ERROR] Testbench compilation failed!"; exit 1; fi
	
	@echo "[ELAB] Elaborating design..."
	@cd $(SIM_DIR) && $(XELAB) -work $(WORK) \
		-top $(TB_VPU_NAME) \
		-debug $(TB_VPU_NAME) \
		2>&1 | tee -a $(abspath $(LOG_DIR))/vpu_elab.log
	@if [ $$? -ne 0 ]; then echo "[ERROR] Elaboration failed!"; exit 1; fi
	
	@echo "[SIM] Running simulation..."
	@cd $(SIM_DIR) && $(XSIM) -work $(WORK) \
		$(TB_VPU_NAME) \
		-log $(abspath $(LOG_DIR))/vpu_simulation.log \
		2>&1 | tee -a $(abspath $(LOG_DIR))/vpu_simulation.log
	@echo ""
	@echo "[RESULTS]"
	@grep -E "\[PASS\]|\[FAIL\]|Final Results" $(LOG_DIR)/vpu_simulation.log || true

# ============================================================================
# Run all testbenches
# ============================================================================

all: tb_pmau tb_vpu
	@echo ""
	@echo "============================================================================"
	@echo "All Testbenches Complete"
	@echo "============================================================================"

# ============================================================================
# Cleaning targets
# ============================================================================

clean: clean_logs clean_waves
	@echo "[CLEAN] Removing simulation artifacts..."
	@rm -rf $(SIM_DIR)
	@echo "[CLEAN] Done."

clean_logs:
	@echo "[CLEAN] Removing log files..."
	@rm -rf $(LOG_DIR)
	@mkdir -p $(LOG_DIR)

clean_waves:
	@echo "[CLEAN] Removing waveform files..."
	@rm -rf $(WAVE_DIR)
	@mkdir -p $(WAVE_DIR)

# ============================================================================
# Default target
# ============================================================================

.DEFAULT_GOAL := help

# ============================================================================
# Print configuration
# ============================================================================

.PHONY: show_config
show_config:
	@echo "Configuration:"
	@echo "  VIVADO_PATH = $(VIVADO_PATH)"
	@echo "  RTL_DIR     = $(RTL_DIR)"
	@echo "  TB_DIR      = $(TB_DIR)"
	@echo "  SIM_DIR     = $(SIM_DIR)"
	@echo "  LOG_DIR     = $(LOG_DIR)"
	@echo "  VERBOSITY   = $(VERBOSITY)"
