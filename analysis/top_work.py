import os
import glob
import pandas as pd

def parse_top_txt(filepath):
    """Estrae i dati utili dai file di testo di top e identifica la cartella 'c'."""
    parsed_data = []
    
    # Il file ora è in c10/raw/, quindi saliamo di due livelli per ottenere 'c10'
    c_level = os.path.basename(os.path.dirname(os.path.dirname(filepath)))
    
    with open(filepath, 'r') as file:
        for line in file:
            # Salta righe vuote, date o intestazioni
            parts = line.strip().split()
            if len(parts) == 3 and parts[1].endswith('m') and parts[2].endswith('Mi'):
                pod_name = parts[0]
                cpu_str = parts[1]
                mem_str = parts[2]
                
                # Rimuove l'hash del pod e l'ID per ottenere il nome del servizio pulito
                service_name = pod_name.rsplit('-', 2)[0]
                
                # Rimuove 'm' e 'Mi' e converte in float
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

def main():
    # Modificato: cerca i txt dentro la sottocartella 'raw' di ogni livello c
    search_pattern = 'experiments/baseline/workload_test/*/raw/top_wrk*.txt'
    file_list = glob.glob(search_pattern)
    
    if not file_list:
        print("Nessun file trovato. Verifica il percorso.")
        return

    all_data = []
    for filepath in file_list:
        all_data.extend(parse_top_txt(filepath))
        
    # Creazione DataFrame pandas generale
    df = pd.DataFrame(all_data)
    
    # Raggruppa i dati in base al livello di concorrenza (c10, c25, c50, ecc.)
    grouped_by_c = df.groupby('Concurrency_Level')
    
    for c_level, group_df in grouped_by_c:
        print(f"--- Elaborazione dati per: {c_level} ---")
        
        out_dir = f'experiments/baseline/workload_test/{c_level}'
        os.makedirs(out_dir, exist_ok=True)
        
        # 1. Export append di tutte le run per questo specifico 'c'
        raw_csv_path = f'{out_dir}/top_wrk_all_runs_{c_level}.csv'
        group_df.to_csv(raw_csv_path, index=False)
        print(f" Salvato file raw: {raw_csv_path}")
        
        # 2. Calcolo media CPU e Memoria raggruppate per Servizio (solo per questo 'c')
        df_mean = group_df.groupby('Service')[['CPU(millicores)', 'Memory(MiB)']].mean().reset_index()
        
        # Arrotonda a due decimali
        df_mean = df_mean.round(2)
        
        # 3. Export delle medie per questo specifico 'c'
        mean_csv_path = f'{out_dir}/top_wrk_avg_{c_level}.csv'
        df_mean.to_csv(mean_csv_path, index=False)
        print(f" Salvato file medie: {mean_csv_path}\n")

if __name__ == "__main__":
    main()