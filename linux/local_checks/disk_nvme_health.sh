#!/usr/bin/env python3
# ==============================================================================
# Local Check Checkmk: Storage Health (SATA SSD, SATA HDD, NVMe)
# ==============================================================================
import sys
import os
import glob
import re
import subprocess
import shutil

def run_smartctl(device):
    try:
        result = subprocess.run(['sudo', 'smartctl', '-a', device], capture_output=True, text=True, check=False)
        return result.stdout
    except Exception:
        return ""

def parse_smartctl_output(text, device_name):
    # Initialize variables
    model = "Unknown Model"
    capacity_bytes = 0
    cap_bracket = "Unknown"
    is_nvme = False
    is_ssd = True # default to SSD unless rotation rate found
    rotation_rate = "Solid State Device"
    smart_status = "PASSED"
    
    # Attributes for SATA
    attributes = {}
    
    # Check device name first
    if "nvme" in device_name.lower():
        is_nvme = True
        
    # Lines
    lines = text.split('\n')
    
    for line in lines:
        line_strip = line.strip()
        if not line_strip:
            continue
            
        # Parse Model
        if line_strip.startswith("Model Number:") or line_strip.startswith("Device Model:"):
            model = line_strip.split(":", 1)[1].strip()
            
        # Parse Capacity
        if line_strip.startswith("User Capacity:") or line_strip.startswith("Total NVM Capacity:"):
            cap_match = re.search(r'([\d,]+)\s+bytes', line_strip)
            if cap_match:
                capacity_bytes = int(cap_match.group(1).replace(",", ""))
            cap_bracket_match = re.search(r'\[([^\]]+)\]', line_strip)
            if cap_bracket_match:
                cap_bracket = cap_bracket_match.group(1).strip()
                
        # Parse Device Type (Rotation Rate / SSD indicator)
        if line_strip.startswith("Rotation Rate:"):
            rotation_rate = line_strip.split(":", 1)[1].strip()
            if "Solid State" in rotation_rate or "SSD" in rotation_rate:
                is_ssd = True
            else:
                is_ssd = False # HDD
                
        # Parse NVMe Indicator from text
        if "NVM Express" in line_strip or "NVMe" in line_strip or "Total NVM Capacity" in line_strip or "Model Number" in line_strip:
            is_nvme = True
            
        # Parse SMART status
        if "SMART overall-health self-assessment test result:" in line_strip:
            smart_status = line_strip.split(":", 1)[1].strip()
        elif "SMART overall-health self-assessment test result" in line_strip:
            parts = line_strip.split()
            if parts:
                smart_status = parts[-1]
                
        # Parse SATA Attributes
        match = re.match(r'^\s*(\d+)\s+([a-zA-Z0-9_-]+)\s+', line)
        if match:
            attr_id = int(match.group(1))
            attr_name = match.group(2)
            rest = line[match.end():]
            dash_match = re.search(r'-\s+(\d+)', rest)
            if dash_match:
                raw_val = int(dash_match.group(1))
            else:
                clean_rest = re.sub(r'\(.*\)', '', rest)
                nums = re.findall(r'\d+', clean_rest)
                raw_val = int(nums[-1]) if nums else 0
            attributes[attr_id] = (attr_name, raw_val)

    # Determine type string
    if is_nvme:
        disk_type = "NVME"
    elif is_ssd:
        disk_type = "SSD Sata"
    else:
        disk_type = "HDD"
        
    # Extract Temp, POH, Smart Status
    # Temperature (ID 194 or ID 190 for SATA, or "Temperature:" for NVMe)
    temp = 0
    if 194 in attributes:
        temp = attributes[194][1]
    elif 190 in attributes:
        temp = attributes[190][1]
    else:
        temp_match = re.search(r'Temperature:\s+(\d+)\s+Celsius', text, re.IGNORECASE)
        if temp_match:
            temp = int(temp_match.group(1))
        else:
            temp_match2 = re.search(r'Temperature:\s+(\d+)', text, re.IGNORECASE)
            if temp_match2:
                temp = int(temp_match2.group(1))
                
    # Power On Hours (ID 9 for SATA, or "Power On Hours:" for NVMe)
    poh = 0
    if 9 in attributes:
        poh = attributes[9][1]
    else:
        poh_match = re.search(r'Power\s+On\s+Hours:\s+([\d,]+)', text, re.IGNORECASE)
        if poh_match:
            poh = int(poh_match.group(1).replace(",", ""))
            
    # Model cleaning
    model_clean = model.strip()
    
    # Capacity fallback if cap_bracket is Unknown
    if cap_bracket == "Unknown" and capacity_bytes > 0:
        gb = capacity_bytes / (1000 ** 3)
        if gb >= 900:
            cap_bracket = f"{gb / 1000.0:.2f} TB"
        else:
            cap_bracket = f"{int(round(gb))} GB"

    # Status word and code based on health/SMART
    status_code = 0
    status_word = "OK"
    
    if disk_type in ["NVME", "SSD Sata"]:
        # Extract health
        health = 100
        if is_nvme:
            percent_used_match = re.search(r'Percentage\s+Used:\s+(\d+)', text, re.IGNORECASE)
            if percent_used_match:
                health = 100 - int(percent_used_match.group(1))
        else:
            if 231 in attributes:
                health = attributes[231][1]
            elif 202 in attributes:
                health = attributes[202][1]
            elif 169 in attributes:
                health = attributes[169][1]
                
        # Check alerts based on standarisasi
        if health <= 80:
            status_code = 2
            status_word = "CRITICAL"
        elif health <= 90:
            status_code = 1
            status_word = "WARNING"
            
        # SMART status check
        if smart_status != "PASSED":
            status_code = 2
            status_word = "CRITICAL"
            
        # Extract Reads and Writes
        read_tb = 0.0
        write_tb = 0.0
        
        if is_nvme:
            # Data Units Read/Written are in 512,000 byte units or printed in TB
            # Search for TB in bracket
            read_match = re.search(r'Data\s+Units\s+Read:\s+[\d,]+\s+\[([\d.]+)\s+TB\]', text, re.IGNORECASE)
            if read_match:
                read_tb = float(read_match.group(1))
            else:
                read_raw_match = re.search(r'Data\s+Units\s+Read:\s+([\d,]+)', text, re.IGNORECASE)
                if read_raw_match:
                    raw_read = int(read_raw_match.group(1).replace(",", ""))
                    read_tb = raw_read * 512000 / (10**12)
                    
            write_match = re.search(r'Data\s+Units\s+Written:\s+[\d,]+\s+\[([\d.]+)\s+TB\]', text, re.IGNORECASE)
            if write_match:
                write_tb = float(write_match.group(1))
            else:
                write_raw_match = re.search(r'Data\s+Units\s+Written:\s+([\d,]+)', text, re.IGNORECASE)
                if write_raw_match:
                    raw_write = int(write_raw_match.group(1).replace(",", ""))
                    write_tb = raw_write * 512000 / (10**12)
        else:
            # SATA SSD
            write_attr = attributes.get(241)
            read_attr = attributes.get(242)
            raw_write = write_attr[1] if write_attr else 0
            raw_read = read_attr[1] if read_attr else 0
            
            # Heuristic for GB vs Sector Scale
            is_gb_scale = any(brand in model.upper() for brand in ["APACER", "CS900", "V-GEN", "PATRIOT", "ADATA", "KINGMAX", "PHISON", "SMI", "SILICON MOTION"])
            if raw_write < 5000000 and poh > 100 and (raw_write / (poh + 1)) > 0.01:
                is_gb_scale = True
                
            if is_gb_scale:
                write_tb = raw_write / 1000.0
                read_tb = raw_read / 1000.0
            else:
                write_tb = raw_write * 512 / (10**12)
                read_tb = raw_read * 512 / (10**12)
                
        # Calculate Write/Day
        days_active = poh / 24.0
        if days_active > 0:
            write_day_gb = (write_tb * 1000.0) / days_active
        else:
            write_day_gb = 0.0
            
        # Calculate Est. Life
        percentage_used = 100 - health
        if percentage_used == 0:
            est_life = ">10 Years"
        else:
            years_active = poh / 8760.0
            est_life_years = years_active * (health / percentage_used)
            if est_life_years > 10:
                est_life = ">10 Years"
            else:
                est_life = f"{est_life_years:.2f} Years"
                
        # Format output string
        output_line = f'{status_code} "Health_Storage ({model_clean})" - Status : {status_word} ❘ Type: {disk_type} ({cap_bracket}) ❘ Status: {smart_status} ❘ Temp: {temp}C ❘ Health: {health}% ❘ Read: {read_tb:.1f} TB ❘ Written: {write_tb:.1f} TB ❘ Write/Day: {write_day_gb:.2f} GB' 
    else:
        # HDD Sata
        reallocated = attributes.get(5)[1] if attributes.get(5) else 0
        pending = attributes.get(197)[1] if attributes.get(197) else 0
        
        remark = "Disk Condition Good"
        if smart_status != "PASSED" or reallocated >= 50 or pending > 10:
            status_code = 2
            status_word = "CRITICAL"
            remark = "Critical, bad sectors or SMART failed!"
        elif reallocated > 0 or pending > 0:
            status_code = 1
            status_word = "WARNING"
            remark = "Warning, some bad sectors detected. Keep monitor!"
            
        rot_rate_clean = rotation_rate.replace(" ", "").replace("RPM", "rpm")
        
        # Format output string for HDD
        output_line = f'{status_code} "Health_Storage ({model_clean})" - Status : {status_word} ❘ Type: HDD ({cap_bracket}) ❘ Status: {smart_status} ❘ Temp: {temp}C ❘ Rotation Rate: {rot_rate_clean} | Realocated Sector: {reallocated}❘ Power On Hours: {poh} Hrs ❘ Remark: {remark}'
        
    return output_line

def get_block_devices():
    devices = []
    # Find SATA disks
    for path in glob.glob('/sys/block/sd*'):
        dev = '/dev/' + os.path.basename(path)
        devices.append(dev)
    # Find NVMe namespaces
    for path in glob.glob('/sys/block/nvme*n*'):
        dev = '/dev/' + os.path.basename(path)
        devices.append(dev)
    return sorted(devices)

def main():
    if not shutil.which('smartctl'):
        print("3 \"Health_Storage\" - UNKNOWN: smartctl is not installed on this system.")
        sys.exit(0)
        
    devices = get_block_devices()
    if not devices:
        print("0 \"Health_Storage\" - Status : OK ❘ No storage devices detected.")
        sys.exit(0)
        
    for dev in devices:
        raw_out = run_smartctl(dev)
        if not raw_out:
            continue
        # Skip if not a valid SMART-capable disk
        if "Device Model:" not in raw_out and "Model Number:" not in raw_out:
            continue
        try:
            line = parse_smartctl_output(raw_out, dev)
            print(line)
        except Exception as e:
            # Fallback if parsing fails to avoid breaking checkmk entirely
            print(f'3 "Health_Storage ({os.path.basename(dev)})" - UNKNOWN: Error parsing SMART data: {str(e)}')

if __name__ == "__main__":
    main()
