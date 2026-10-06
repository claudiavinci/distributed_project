import os
import glob
import re
import pandas as pd

# ==========================================
# FUNZIONI PER L'ESTRAZIONE DEI DATI (TOP)
# ==========================================
def parse_top_txt(filepath):
    """Estrae i dati utili dai file di testo di top e identifica la cartella 'c'."""
    parsed_data = []
    c_level = os.path.basename(os.path.dirname(os.path.dirname(filepath)))
    
    with open(filepath, 'r') as file:
        for line in file:
            parts = line.strip().split()
            if len(parts) == 3 and parts[1].endswith('m') and parts[2].endswith('Mi'):
                pod_name = parts[0]
                cpu_str = parts[1]
                mem_str = parts[2]
                
                service_name = pod_name.rsplit('-', 2)[0]
                cpu_val = float(cpu_str.replace('m', ''))
                mem_val = float(mem_str.replace('Mi', ''))
                
                parsed_data.append({
                    'Concurrency_Level': c_level,
                    'Service': service_name,
                    'CPU(millicores)': cpu_val,
                    'Memory(MiB)': mem_val,
                    'Source_File': os.path.basename(filepath)
                })
    return parsed_data

# ==========================================
# FUNZIONI PER L'ESTRAZIONE DEI DATI (WRK)
# ==========================================
def parse_time_to_ms(time_str):
    """Converte le metriche temporali di wrk (us, ms, s, m) in millisecondi."""
    if not time_str:
        return None
    time_str = time_str.strip()
    
    if time_str.endswith('ms'):
        return float(time_str[:-2])
    elif time_str.endswith('us'):
        return float(time_str[:-2]) / 1000
    elif time_str.endswith('m'):
        return float(time_str[:-1]) * 60000
    elif time_str.endswith('s'):
        return float(time_str[:-1]) * 1000
    
    return float(re.sub(r'[a-zA-Z]', '', time_str))

def parse_size_to_mb(size_str):
    """Converte le metriche di trasferimento dati in Megabytes (MB)."""
    if not size_str:
        return None
    
    size_str = size_str.strip().upper()
    
    val = float(re.sub(r'[A-Z]', '', size_str))
    
    if size_str.endswith('GB'):
        return val * 1024
    elif size_str.endswith('MB'):
        return val
    elif size_str.endswith('KB'):
        return val / 1024
    elif size_str.endswith('B'):
        return val / (1024 * 1024)
    
    return val / (1024 * 1024)

def extract_match(pattern, text, group=1):
    """Esegue la regex e restituisce il match in modo sicuro."""
    match = re.search(pattern, text)
    return match.group(group) if match else None

def parse_wrk_txt(filepath):
    """Legge un file wrk e restituisce un dizionario con i dati estratti."""
    with open(filepath, 'r') as file:
        text = file.read()
        
    c_level = os.path.basename(os.path.dirname(os.path.dirname(filepath)))

    return {
        'Concurrency_Level': c_level,
        'Source_File': os.path.basename(filepath),
        'Threads': int(extract_match(r'(\d+)\s+threads and', text) or 0),
        'Connections': int(extract_match(r'and\s+(\d+)\s+connections', text) or 0),
        'Avg_Latency_ms': parse_time_to_ms(extract_match(r'Latency\s+([\d\.]+[a-z]+)', text)),
        'Max_Latency_ms': parse_time_to_ms(extract_match(r'Latency\s+[\d\.]+[a-z]+\s+[\d\.]+[a-z]+\s+([\d\.]+[a-z]+)', text)),
        'P50_Latency_ms': parse_time_to_ms(extract_match(r'50%\s+([\d\.]+[a-z]+)', text)),
        'P75_Latency_ms': parse_time_to_ms(extract_match(r'75%\s+([\d\.]+[a-z]+)', text)),
        'P90_Latency_ms': parse_time_to_ms(extract_match(r'90%\s+([\d\.]+[a-z]+)', text)),
        'P99_Latency_ms': parse_time_to_ms(extract_match(r'99%\s+([\d\.]+[a-z]+)', text)),
        'Total_Requests': int(extract_match(r'(\d+)\s+requests in', text) or 0),
        'Timeouts': int(extract_match(r'timeout\s+(\d+)', text) or 0),
        'Req_per_Sec': float(extract_match(r'Requests/sec:\s+([\d\.]+)', text) or 0.0),
        'Transfer_per_Sec_MB': parse_size_to_mb(extract_match(r'Transfer/sec:\s+(.+)', text))
    }

# ---------------------------------------------------------
# 1. ELABORAZIONE METRICHE TOP (CPU/MEM)
# ---------------------------------------------------------

def top_metrics_processing(top_pattern, out_dir_base):
    print("--- Elaborazione metriche TOP ---")
    top_files = glob.glob(top_pattern)
    
    if not top_files:
        print(" Nessun file TOP trovato.")
    else:
        top_data = [item for filepath in top_files for item in parse_top_txt(filepath)]
        df_top = pd.DataFrame(top_data)
        
        for c_level, group_df in df_top.groupby('Concurrency_Level'):
            out_dir = f'{out_dir_base}/{c_level}'
            os.makedirs(out_dir, exist_ok=True)
            
            raw_csv_path = f'{out_dir}/top_wrk_all_runs_{c_level}.csv'
            group_df.to_csv(raw_csv_path, index=False)
            
            df_top_mean = group_df.groupby('Service')[['CPU(millicores)', 'Memory(MiB)']].mean().reset_index().round(2)
            
            mean_csv_path = f'{out_dir}/top_wrk_avg_{c_level}.csv'
            df_top_mean.to_csv(mean_csv_path, index=False)
            print(f"[{c_level}] Salvati CSV TOP: {raw_csv_path} | {mean_csv_path}")

# ---------------------------------------------------------
# 2. ELABORAZIONE METRICHE WRK (LATENZA/THROUGHPUT)
# ---------------------------------------------------------

def wrk_metrics_processing(wrk_pattern, out_dir_base):
    print("\n--- Elaborazione metriche WRK ---")
    wrk_files = glob.glob(wrk_pattern)
    
    if not wrk_files:
        print(" Nessun file WRK trovato.")
    else:
        wrk_data = [parse_wrk_txt(filepath) for filepath in wrk_files]
        df_wrk = pd.DataFrame(wrk_data)
        
        for c_level, group_df in df_wrk.groupby('Concurrency_Level'):
            out_dir = f'{out_dir_base}/{c_level}'
            os.makedirs(out_dir, exist_ok=True)
            
            raw_csv_path = f'{out_dir}/wrk_all_runs_{c_level}.csv'
            group_df.to_csv(raw_csv_path, index=False)
            
            # Calcola la media di tutte le colonne numeriche
            df_wrk_mean = group_df.mean(numeric_only=True).round(2).to_frame().T
            df_wrk_mean.insert(0, 'Concurrency_Level', c_level)
            
            mean_csv_path = f'{out_dir}/wrk_avg_{c_level}.csv'
            df_wrk_mean.to_csv(mean_csv_path, index=False)
            print(f"[{c_level}] Salvati CSV WRK: {raw_csv_path} | {mean_csv_path}")

# ==========================================
# MAIN ROUTINE UNIFICATA
# ==========================================

def main():
    print("Inizio elaborazione dati baseline...\n")
    wrk_metrics_processing(wrk_pattern='experiments/baseline/workload_test/*/raw/wrk*.txt',
                           out_dir_base='experiments/baseline/workload_test/')
    top_metrics_processing(top_pattern='experiments/baseline/workload_test/*/raw/top_wrk*.txt',
                           out_dir_base='experiments/baseline/workload_test/')
    print("\nElaborazione completata!")

if __name__ == "__main__":
    main()