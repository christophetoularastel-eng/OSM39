import tkinter as tk
from tkinter import filedialog, messagebox

class FontEditorApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Éditeur de Police 8x16 - ROM 8 Ko")
        
        # Initialisation de la ROM (8192 octets remplis de 0)
        self.rom_data = bytearray(8192)
        self.current_char = 0
        self.current_page = 0 # 0 pour A12=0, 1 pour A12=1
        
        # Taille de la grille (8x16) et taille d'un pixel à l'écran
        self.cols = 8
        self.rows = 16
        self.cell_size = 30
        
        self.setup_ui()
        self.draw_grid()

    def setup_ui(self):
        # --- Panneau de contrôle haut ---
        control_frame = tk.Frame(self.root, pady=10)
        control_frame.pack()
        
        tk.Button(control_frame, text="Charger ROM (.bin)", command=self.load_rom).pack(side=tk.LEFT, padx=5)
        tk.Button(control_frame, text="Sauvegarder ROM (.bin)", command=self.save_rom).pack(side=tk.LEFT, padx=5)
        
        # --- Panneau central (Grille) ---
        self.canvas = tk.Canvas(self.root, width=self.cols * self.cell_size, height=self.rows * self.cell_size, bg="black")
        self.canvas.pack(pady=10)
        self.canvas.bind("<Button-1>", self.toggle_pixel) # Clic gauche
        self.canvas.bind("<B1-Motion>", self.draw_pixel)  # Glisser pour dessiner
        
        # --- Panneau de navigation bas ---
        nav_frame = tk.Frame(self.root)
        nav_frame.pack(pady=10)
        
        tk.Button(nav_frame, text="<< Précédent", command=self.prev_char).pack(side=tk.LEFT, padx=5)
        
        self.char_label = tk.Label(nav_frame, text=self.get_char_info(), font=("Courier", 12, "bold"))
        self.char_label.pack(side=tk.LEFT, padx=15)
        
        tk.Button(nav_frame, text="Suivant >>", command=self.next_char).pack(side=tk.LEFT, padx=5)
        
        # --- Sélection de la page ---
        page_frame = tk.Frame(self.root)
        page_frame.pack(pady=5)
        tk.Label(page_frame, text="Page EEPROM (A12) :").pack(side=tk.LEFT)
        self.page_var = tk.IntVar(value=0)
        tk.Radiobutton(page_frame, text="Page 0 (0-4Ko)", variable=self.page_var, value=0, command=self.change_page).pack(side=tk.LEFT)
        tk.Radiobutton(page_frame, text="Page 1 (4-8Ko)", variable=self.page_var, value=1, command=self.change_page).pack(side=tk.LEFT)

    def get_char_info(self):
        return f"Caractère : {self.current_char} (0x{self.current_char:02X})"

    def get_byte_offset(self, row):
        # Calcule l'adresse dans la ROM : (Page * 4096) + (Char * 16) + Ligne
        return (self.current_page * 4096) + (self.current_char * 16) + row

    def draw_grid(self):
        self.canvas.delete("all")
        for r in range(self.rows):
            # Lecture de l'octet correspondant à la ligne courante
            byte_val = self.rom_data[self.get_byte_offset(r)]
            
            for c in range(self.cols):
                # Le bit de poids fort (7) correspond au pixel le plus à gauche
                bit_index = 7 - c
                is_set = (byte_val >> bit_index) & 1
                
                color = "green" if is_set else "black" # Style moniteur phosphore vert !
                
                x1 = c * self.cell_size
                y1 = r * self.cell_size
                x2 = x1 + self.cell_size
                y2 = y1 + self.cell_size
                
                self.canvas.create_rectangle(x1, y1, x2, y2, fill=color, outline="gray")

    def toggle_pixel(self, event, force_set=None):
        c = event.x // self.cell_size
        r = event.y // self.cell_size
        
        if 0 <= c < self.cols and 0 <= r < self.rows:
            offset = self.get_byte_offset(r)
            byte_val = self.rom_data[offset]
            bit_index = 7 - c
            
            if force_set is None:
                # Inverse le bit
                self.rom_data[offset] ^= (1 << bit_index)
            else:
                # Force à 1 (pour le dessin au glisser)
                self.rom_data[offset] |= (1 << bit_index)
                
            self.draw_grid()

    def draw_pixel(self, event):
        self.toggle_pixel(event, force_set=True)

    def next_char(self):
        self.current_char = (self.current_char + 1) % 256
        self.update_view()

    def prev_char(self):
        self.current_char = (self.current_char - 1) % 256
        self.update_view()

    def change_page(self):
        self.current_page = self.page_var.get()
        self.update_view()

    def update_view(self):
        self.char_label.config(text=self.get_char_info())
        self.draw_grid()

    def load_rom(self):
        filepath = filedialog.askopenfilename(filetypes=[("Fichiers BIN/ROM", "*.bin *.rom"), ("Tous les fichiers", "*.*")])
        if filepath:
            try:
                with open(filepath, "rb") as f:
                    data = f.read()
                    if len(data) <= 8192:
                        self.rom_data[:len(data)] = data
                        self.draw_grid()
                        messagebox.showinfo("Succès", "ROM chargée avec succès !")
                    else:
                        messagebox.showwarning("Attention", "Le fichier est plus grand que 8 Ko, seuls les 8192 premiers octets ont été chargés.")
            except Exception as e:
                messagebox.showerror("Erreur", f"Impossible de lire le fichier :\n{e}")

    def save_rom(self):
        filepath = filedialog.asksaveasfilename(defaultextension=".bin", filetypes=[("Fichier BIN", "*.bin")])
        if filepath:
            try:
                with open(filepath, "wb") as f:
                    f.write(self.rom_data)
                messagebox.showinfo("Succès", "ROM sauvegardée avec succès !")
            except Exception as e:
                messagebox.showerror("Erreur", f"Impossible de sauvegarder le fichier :\n{e}")

if __name__ == "__main__":
    root = tk.Tk()
    app = FontEditorApp(root)
    root.mainloop()