import os
import sys

import tkinter as tk
from tkinter import ttk, filedialog, messagebox, simpledialog
from egofs_core import OSMFS_Core

class EgoFS_GUI:
    def __init__(self, root):
        self.root = root
        self.root.title("OSMFS Explorer - Gestionnaire 6809 OSM09")
        self.root.geometry("750x450")
        
        self.core = None
        
        # --- Zone Haute : Connexion ---
        frame_top = tk.Frame(root, pady=10)
        frame_top.pack(fill=tk.X, padx=10)

        tk.Label(frame_top, text="Disque / Image :").pack(side=tk.LEFT)
        self.entry_device = tk.Entry(frame_top, width=30)
        default_device = sys.argv[1] if len(sys.argv) > 1 else "fausse_sd.img"
        self.entry_device.insert(0, default_device)
        self.entry_device.pack(side=tk.LEFT, padx=10)

        # On sauvegarde le bouton dans 'self' pour pouvoir changer son texte
        self.btn_connect = tk.Button(frame_top, text="Connecter", command=self.toggle_connect)
        self.btn_connect.pack(side=tk.LEFT)

        tk.Button(frame_top, text="Formater OSMFS", command=self.format_fs, fg="red").pack(side=tk.RIGHT)

        # --- Zone Centrale : Explorateur (Treeview) ---
        columns = ("index", "name", "rwx", "size", "sectors", "lba", "page", "addr")
        self.tree = ttk.Treeview(root, columns=columns, show="headings", height=12)
        
        # On cache la colonne index qui ne sert qu'à la logique interne
        self.tree.column("index", width=0, stretch=tk.NO) 
        
        self.tree.heading("name", text="Nom du Fichier")
        self.tree.heading("rwx", text="Attributs")
        self.tree.heading("size", text="Taille (octets)")
        self.tree.heading("sectors", text="Secteurs")
        self.tree.heading("lba", text="LBA Départ")
        self.tree.heading("page", text="Page Boot")
        self.tree.heading("addr", text="Adresse Boot")
        
        self.tree.column("name", width=200)
        self.tree.column("size", width=100, anchor=tk.CENTER)
        self.tree.column("sectors", width=80, anchor=tk.CENTER)
        self.tree.column("lba", width=100, anchor=tk.CENTER)
        self.tree.column("page", width=80, anchor=tk.CENTER)
        self.tree.column("addr", width=100, anchor=tk.CENTER)
        
        self.tree.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)
        
        # --- Zone Basse : Actions ---
        frame_bottom = tk.Frame(root, pady=10)
        frame_bottom.pack(fill=tk.X, padx=10)
        
        tk.Button(frame_bottom, text="⬇ Injecter vers SD", command=self.inject_file).pack(side=tk.LEFT, padx=5)
        tk.Button(frame_bottom, text="⬆ Extraire vers PC", command=self.extract_file).pack(side=tk.LEFT, padx=5)
        tk.Button(frame_bottom, text="✖ Supprimer", command=self.delete_file).pack(side=tk.RIGHT, padx=5)

        if len(sys.argv) > 1:
            self.root.after(200, self.toggle_connect)

    def toggle_connect(self):
        if self.core is None:
            # --- Action : CONNECTER ---
            device = self.entry_device.get()
            if not os.path.exists(device):
                messagebox.showerror("Erreur", f"Le périphérique '{device}' est introuvable.")
                return

            self.core = OSMFS_Core(device)
            self.refresh_list()

            # Mise à jour de l'interface
            self.btn_connect.config(text="Déconnecter")
            self.entry_device.config(state="disabled") # Empêche de modifier le chemin
            messagebox.showinfo("Connecté", f"Connecté avec succès à {device}")

        else:
            # --- Action : DÉCONNECTER ---
            self.core = None # Détruit l'objet, "libérant" virtuellement l'accès
            self.refresh_list() # Va vider le Treeview

            # Mise à jour de l'interface
            self.btn_connect.config(text="Connecter")
            self.entry_device.config(state="normal") # Réactive le champ de saisie

    def refresh_list(self):
        # Efface la liste actuelle
        for item in self.tree.get_children():
            self.tree.delete(item)
            
        if self.core:
            files = self.core.list_files()
            for f in files:
                self.tree.insert("", tk.END, values=(f['index'], f['path'] + ('/' if f['is_dir'] else ''), f['rwx'], f['size'], f['sectors'], f['lba'], f['page'], f['addr']))

    def format_fs(self):
        if not self.core:
            return messagebox.showwarning("Attention", "Connectez d'abord un disque.")
            
        if messagebox.askyesno("Danger", "Formater effacera tout le répertoire. Continuer ?"):
            if self.core.format_fs():
                messagebox.showinfo("Succès", "Formatage terminé.")
                self.refresh_list()

    def inject_file(self):
        if not self.core:
            return messagebox.showwarning("Attention", "Connectez un disque.")

        # askopenfilenames (avec un 's') permet la sélection multiple
        local_paths = filedialog.askopenfilenames(title="Choisir des fichiers à injecter")
        if not local_paths:
            return

        # On demande les paramètres système UNE SEULE FOIS pour tout le lot
        boot_page = simpledialog.askinteger("Page", "Page de boot par défaut (0-3) :", initialvalue=0, minvalue=0, maxvalue=3)
        if boot_page is None: return

        boot_addr = simpledialog.askstring("Adresse", "Adresse d'exécution (Hexa, ex: 0000) :", initialvalue="0000")
        if not boot_addr: return

        success_count = 0
        error_messages = []

        # Boucle d'injection pour chaque fichier sélectionné
        for local_path in local_paths:
            # Récupère le nom du fichier (ex: "JEU.BIN") et le passe en majuscules
            base_name = os.path.basename(local_path).upper()

            # Tronque à 15 caractères maximum pour l'OSMFS
            ego_name = base_name[:15]

            try:
                # Appelle le core pour écrire sur la carte SD
                if self.core.inject_file(local_path, ego_name, boot_page, boot_addr):
                    success_count += 1
            except Exception as e:
                error_messages.append(f"{ego_name}: {e}")

        # Met à jour l'affichage une fois que tout le lot est copié
        self.refresh_list()

        # Résumé de l'opération
        if error_messages:
            messagebox.showwarning("Terminé avec des erreurs",
                                   f"{success_count} injectés.\nErreurs :\n" + "\n".join(error_messages))
        elif success_count > 0:
            messagebox.showinfo("Succès", f"{success_count} fichier(s) injecté(s) avec succès !")

    def delete_file(self):
        selected = self.tree.focus()
        if not selected: return messagebox.showwarning("Attention", "Sélectionnez un fichier.")
        
        values = self.tree.item(selected, 'values')
        index = int(values[0]) # L'index interne dans le répertoire
        name = values[1]
        
        if messagebox.askyesno("Confirmation", f"Supprimer le fichier '{name}' ?"):
            self.core.delete_file(index)
            self.refresh_list()

    def extract_file(self):
        selected = self.tree.focus()
        if not selected: return messagebox.showwarning("Attention", "Sélectionnez un fichier.")
        
        values = self.tree.item(selected, 'values')
        index = int(values[0])
        name = values[1]
        
        dest_path = filedialog.asksaveasfilename(title="Enregistrer sous...", initialfile=f"{name}.bin")
        if dest_path:
            self.core.extract_file(index, dest_path)
            messagebox.showinfo("Succès", "Fichier extrait avec succès !")

if __name__ == "__main__":
    root = tk.Tk()
    app = EgoFS_GUI(root)
    root.mainloop()
