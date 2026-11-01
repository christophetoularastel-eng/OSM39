import os
import struct

OSMFS_MAGIC = b"OSMF"
OSMFS_MAGIC_OFFSET = 508
OSMFS_ENTRY_FORMAT = ">B 15s I I B H B 4s"
OSMFS_SECTOR_SIZE = 512
OSMFS_DIR_LBA = 1
OSMFS_DIR_SIZE = 256           # NOUVEAU : Taille du répertoire (secteurs)
OSMFS_DATA_START = 257         # NOUVEAU : Début des données
OSMFS_ENTRY_SIZE = 32
OSMFS_ENTRIES_PER_SECTOR = OSMFS_SECTOR_SIZE // OSMFS_ENTRY_SIZE
# Attributs (+27) : bit0 x, bit1 w, bit2 r, bit3 cache, bit4 a (application
# OSM-VISION). Masque a $1F : a $0F, le bit 4 n'arrivait jamais sur la carte.
OSMFS_ATTR_MASK = 0x3F
# bit5 d : dossier (entree de taille 0). Le parent de chaque entree est a
# +28 (16 bits BE) : 0 = racine, sinon n° de l'entree du dossier + 1, avec
# n° = (LBA - 1) * 16 + rang (le meme que 'index'). Une carte d'avant les
# dossiers a 0 partout : tout y est a la racine (bios/osmfs.asm).
OSMFS_ATTR_DIR = 0x20
OSMFS_DIR_ATTR = 0x27          # rwx + d, comme FS_MkDir

class OSMFS_Core:
    def __init__(self, device_path):
        self.device_path = device_path
        self.sector_size = OSMFS_SECTOR_SIZE
        self.dir_lba = OSMFS_DIR_LBA
        self.dir_size = OSMFS_DIR_SIZE
        self.data_start = OSMFS_DATA_START
        self.entry_format = OSMFS_ENTRY_FORMAT
        self.entry_size = OSMFS_ENTRY_SIZE
        self.entries_per_sector = OSMFS_ENTRIES_PER_SECTOR

    def _read_sector(self, fd, lba):
        fd.seek(lba * self.sector_size)
        return fd.read(self.sector_size)

    def _write_sector(self, fd, lba, data):
        if len(data) < self.sector_size:
            data = data.ljust(self.sector_size, b'\x00')
        fd.seek(lba * self.sector_size)
        fd.write(data)

    @staticmethod
    def _sync(fd):
        """Force l'ecriture physique sur la carte. Sans cela, le noyau garde
        les secteurs en cache : une carte retiree trop tot peut perdre une
        partie des ecritures (une entree de repertoire sans ses donnees, ou
        l'inverse), alors que la relecture, servie par ce meme cache, dit
        que tout va bien."""
        fd.flush()
        os.fsync(fd.fileno())

    @staticmethod
    def _sectors_for(size_bytes):
        return (size_bytes + 511) // 512

    @staticmethod
    def _rwx_str(attr):
        r = 'r' if attr & 0x04 else '-'
        w = 'w' if attr & 0x02 else '-'
        x = 'x' if attr & 0x01 else '-'
        a = 'a' if attr & 0x10 else ''
        return r + w + x + a

    @staticmethod
    def detect(device_path):
        try:
            with open(device_path, 'rb') as fd:
                boot = fd.read(OSMFS_SECTOR_SIZE)
                if boot[OSMFS_MAGIC_OFFSET : OSMFS_MAGIC_OFFSET + len(OSMFS_MAGIC)] == OSMFS_MAGIC:
                    return True
                fd.seek(0, 2)
                dev_size = fd.tell()
                fd.seek(OSMFS_DIR_LBA * OSMFS_SECTOR_SIZE)
                dir_data = fd.read(OSMFS_SECTOR_SIZE)
                valid = 0
                for i in range(OSMFS_ENTRIES_PER_SECTOR):
                    raw = dir_data[i * OSMFS_ENTRY_SIZE : (i + 1) * OSMFS_ENTRY_SIZE]
                    status = raw[0]
                    if status not in (0x00, 0x01, 0xE5):
                        return False
                    if status == 0x01:
                        _, _, lba, size, page, _, _, _ = struct.unpack(OSMFS_ENTRY_FORMAT, raw)
                        # MODIFIÉ : lba doit être >= à DATA_START
                        if lba < OSMFS_DATA_START or size > dev_size or page > 3:
                            return False
                        valid += 1
                return valid > 0
        except Exception:
            return False

    def format_fs(self):
        try:
            with open(self.device_path, 'rb+') as fd:
                boot_sector = bytearray(self._read_sector(fd, 0))
                if not any(boot_sector):
                    boot_sector[OSMFS_MAGIC_OFFSET : OSMFS_MAGIC_OFFSET + len(OSMFS_MAGIC)] = OSMFS_MAGIC
                    self._write_sector(fd, 0, bytes(boot_sector))

                # MODIFIÉ : On efface les 256 secteurs du répertoire
                empty_dir = b'\x00' * self.sector_size
                for lba in range(self.dir_lba, self.dir_lba + self.dir_size):
                    self._write_sector(fd, lba, empty_dir)
                self._sync(fd)

                print(f"[*] OSMFS formaté avec succès sur {self.device_path}.")
                return True
        except PermissionError:
            print("[!] Erreur : Accès refusé.")
            return False

    def list_files(self):
        files = []
        try:
            with open(self.device_path, 'rb') as fd:
                global_index = 0
                # MODIFIÉ : On parcourt tous les secteurs du répertoire
                for lba in range(self.dir_lba, self.dir_lba + self.dir_size):
                    dir_data = self._read_sector(fd, lba)
                    for i in range(self.entries_per_sector):
                        offset = i * self.entry_size
                        raw_entry = dir_data[offset : offset + self.entry_size]
                        status, name_b, f_lba, size, page, addr, attr, res = struct.unpack(self.entry_format, raw_entry)

                        if status == 0x01:
                            name = name_b.decode('ascii', errors='ignore').rstrip(' ').rstrip('\x00')
                            files.append({
                                'parent': (res[0] << 8) | res[1],
                                'id': global_index + 1,
                                'is_dir': bool(attr & OSMFS_ATTR_DIR),
                                'index': global_index, # Index absolu indispensable pour la GUI
                                'name': name,
                                'lba': f_lba,
                                'size': size,
                                'sectors': self._sectors_for(size),
                                'page': page,
                                'addr': hex(addr),
                                'attr': attr,
                                'rwx': self._rwx_str(attr)
                            })
                        global_index += 1
        except Exception as e:
            print(f"[!] Erreur de lecture : {e}")
        # chemin complet : "APPS/GLOUTON.ASM" ("?/NOM" si le parent manque)
        par_id = {f['id']: f for f in files if f['is_dir']}
        for f in files:
            parts, p, vus = [f['name']], f['parent'], set()
            while p and p not in vus:
                vus.add(p)
                d = par_id.get(p)
                if not d:
                    parts.append('?')
                    break
                parts.append(d['name'])
                p = d['parent']
            f['path'] = '/'.join(reversed(parts))
        return files

    # --- Dossiers ---
    @staticmethod
    def split_path(path):
        """'APPS/X.ASM' -> (['APPS'], 'X.ASM') ; noms en majuscules."""
        parts = [p for p in path.upper().replace('\\', '/').split('/') if p not in ('', '.')]
        if not parts:
            return [], ''
        return parts[:-1], parts[-1]

    def find_entry(self, name, parent, files=None):
        files = self.list_files() if files is None else files
        name = name.upper()[:15]
        for f in files:
            if f['name'] == name and f['parent'] == parent:
                return f
        return None

    def resolve_dir(self, dirs, create=False):
        """Liste de noms de dossiers depuis la racine -> n° (0 = racine).
        None si un dossier manque (et create faux)."""
        parent = 0
        for d in dirs:
            f = self.find_entry(d, parent)
            if f and not f['is_dir']:
                print(f"[!] '{d}' existe et n'est pas un dossier.")
                return None
            if not f:
                if not create:
                    return None
                f = self._new_entry(d, parent, self.data_start, 0, 0, 0, OSMFS_DIR_ATTR)
                if f is None:
                    return None
                print(f"[*] Dossier '{d}' créé.")
            parent = f['id']
        return parent

    def mkdir(self, path):
        dirs, last = self.split_path(path)
        return self.resolve_dir(dirs + ([last] if last else []), create=True)

    def _new_entry(self, name, parent, lba, size, page, addr, attr):
        """Ecrit une entree dans le premier emplacement libre ; la rend."""
        entry = struct.pack(self.entry_format, 0x01, name.upper().encode('ascii')[:15].ljust(15, b' '),
                            lba, size, page, addr, attr & OSMFS_ATTR_MASK,
                            bytes([parent >> 8, parent & 0xFF, 0, 0]))
        with open(self.device_path, 'rb+') as fd:
            for lba_d in range(self.dir_lba, self.dir_lba + self.dir_size):
                data = bytearray(self._read_sector(fd, lba_d))
                for i in range(self.entries_per_sector):
                    o = i * self.entry_size
                    if data[o] in (0x00, 0xE5):
                        data[o:o + self.entry_size] = entry
                        self._write_sector(fd, lba_d, bytes(data))
                        self._sync(fd)
                        idx = (lba_d - self.dir_lba) * self.entries_per_sector + i
                        return {'id': idx + 1, 'index': idx, 'name': name.upper()[:15],
                                'parent': parent, 'is_dir': bool(attr & OSMFS_ATTR_DIR)}
        print("[!] Erreur : Le répertoire est plein.")
        return None

    def inject_file(self, local_path, osm_name, boot_page, boot_addr, attr=0x07):
        # un chemin "APPS/X.ASM" : les dossiers sont créés au besoin
        dirs, base = self.split_path(osm_name)
        parent = self.resolve_dir(dirs, create=True)
        if parent is None:
            return False
        files = self.list_files()

        target_lba = -1
        target_offset = -1

        name_encoded = base.encode('ascii')[:15].ljust(15, b' ')
        parent_b = bytes([parent >> 8, parent & 0xFF])

        with open(self.device_path, 'rb+') as fd:
            # 0. Remplacer : reperer les entrees valides du meme nom. Elles
            #    seront marquees effacees APRES l'ecriture de la nouvelle
            #    (un echec en cours de route ne perd pas l'ancienne version).
            #    Sans cela, la machine trouve la PREMIERE entree, donc
            #    l'ancienne. Leurs secteurs ne sont pas recuperes (allocation
            #    contigue apres le dernier fichier, comme le BIOS).
            old_entries = []
            for lba in range(self.dir_lba, self.dir_lba + self.dir_size):
                dir_data = self._read_sector(fd, lba)
                for i in range(self.entries_per_sector):
                    offset = i * self.entry_size
                    if dir_data[offset] == 0x01 and \
                       dir_data[offset + 1 : offset + 16] == name_encoded and \
                       dir_data[offset + 28 : offset + 30] == parent_b:
                        if dir_data[offset + 27] & OSMFS_ATTR_DIR:
                            print(f"[!] '{osm_name}' est un dossier.")
                            return False
                        old_entries.append((lba, offset))

            # 1. Chercher un slot libre sur tous les secteurs
            for lba in range(self.dir_lba, self.dir_lba + self.dir_size):
                dir_data = self._read_sector(fd, lba)
                for i in range(self.entries_per_sector):
                    offset = i * self.entry_size
                    if dir_data[offset] in (0x00, 0xE5):
                        target_lba = lba
                        target_offset = offset
                        break
                if target_lba != -1:
                    break

            if target_lba == -1:
                print("[!] Erreur : Le répertoire est plein.")
                return False

            # 2. Calculer le LBA de destination (après le dernier fichier ou DATA_START_LBA)
            next_free_lba = self.data_start
            for f in files:
                file_end = f['lba'] + f['sectors']
                if file_end > next_free_lba:
                    next_free_lba = file_end

            # 3. Préparer et écrire le fichier binaire
            file_size_bytes = os.path.getsize(local_path)
            sectors_needed = self._sectors_for(file_size_bytes)

            with open(local_path, 'rb') as f_in:
                print(f"[*] Écriture de {sectors_needed} secteurs au LBA {next_free_lba}...")
                current_lba = next_free_lba
                while chunk := f_in.read(self.sector_size):
                    self._write_sector(fd, current_lba, chunk)
                    current_lba += 1

            # 5. Mettre à jour l'entrée du répertoire sur le bon secteur
            new_entry = struct.pack(
                self.entry_format,
                0x01, name_encoded, next_free_lba, file_size_bytes,
                boot_page, int(boot_addr, 16), attr & OSMFS_ATTR_MASK, parent_b + b'\x00' * 2
            )

            dir_data = bytearray(self._read_sector(fd, target_lba))
            dir_data[target_offset : target_offset + self.entry_size] = new_entry
            self._write_sector(fd, target_lba, bytes(dir_data))

            # 6. Effacer l'ancienne version, maintenant que la nouvelle existe
            for lba, offset in old_entries:
                dir_data = bytearray(self._read_sector(fd, lba))
                dir_data[offset] = 0xE5
                self._write_sector(fd, lba, bytes(dir_data))
                print(f"[*] Ancienne entrée '{osm_name}' remplacée.")

            self._sync(fd)
            print(f"[*] Fichier '{osm_name}' injecté avec succès !")
            return True

    # --- Utilitaires de conversion Index Absolu -> LBA/Offset ---
    def _get_location_from_index(self, index):
        sector_lba = self.dir_lba + (index // self.entries_per_sector)
        local_offset = (index % self.entries_per_sector) * self.entry_size
        return sector_lba, local_offset

    def delete_file(self, index):
        files = self.list_files()
        if any(f['parent'] == index + 1 for f in files):
            print("[!] Dossier non vide : rien n'est effacé.")
            return False
        target_lba, target_offset = self._get_location_from_index(index)
        with open(self.device_path, 'rb+') as fd:
            dir_data = bytearray(self._read_sector(fd, target_lba))
            dir_data[target_offset] = 0xE5
            self._write_sector(fd, target_lba, bytes(dir_data))
            self._sync(fd)
            return True

    def set_attributes(self, index, attr):
        target_lba, target_offset = self._get_location_from_index(index)
        with open(self.device_path, 'rb+') as fd:
            dir_data = bytearray(self._read_sector(fd, target_lba))
            dir_data[target_offset + 27] = attr & OSMFS_ATTR_MASK
            self._write_sector(fd, target_lba, bytes(dir_data))
            self._sync(fd)
            return True

    def set_attributes_by_name(self, name, attr):
        dirs, base = self.split_path(name)
        parent = self.resolve_dir(dirs)
        f = self.find_entry(base, parent) if parent is not None else None
        if f:
            return self.set_attributes(f['index'], attr)
        print(f"[!] Fichier '{name}' introuvable dans le répertoire.")
        return False

    def extract_file(self, index, dest_path):
        files = self.list_files()
        target = next((f for f in files if f['index'] == index), None)
        if not target: return False

        remaining = target['size']
        with open(self.device_path, 'rb') as fd_in, open(dest_path, 'wb') as f_out:
            for i in range(target['sectors']):
                sector_data = self._read_sector(fd_in, target['lba'] + i)
                chunk = sector_data[:min(self.sector_size, remaining)]
                f_out.write(chunk)
                remaining -= len(chunk)
        return True
