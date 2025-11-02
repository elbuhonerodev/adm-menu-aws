#!/bin/bash

# Script de instalación automática para AWS CloudFront Manager
# Este script descargará e instalará todo automáticamente

set -e

# Colores para output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Funciones de color
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_header() { echo -e "${CYAN}$1${NC}"; }

# URLs de GitHub (actualizar con tu repositorio)
GITHUB_REPO="https://github.com/tu-usuario/aws-cloudfront-manager"
RAW_BASE="https://raw.githubusercontent.com/tu-usuario/aws-cloudfront-manager/main"

# Directorios
INSTALL_DIR="/root/aws-cloudfront-manager"
BACKUP_DIR="/root/aws-backup-$(date +%Y%m%d_%H%M%S)"

# Barra de carga animada
show_progress() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    printf "    "
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Verificar si es root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Este script debe ejecutarse como root"
        echo "Usa: sudo bash install.sh"
        exit 1
    fi
}

# Crear directorio de instalación
create_install_dir() {
    print_info "Creando directorio de instalación..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
}

# Descargar archivos desde GitHub
download_files() {
    print_info "Descargando archivos desde GitHub..."
    
    local files=("aws-config-menu.sh" "dependencias-menu-aws.sh")
    
    for file in "${files[@]}"; do
        print_info "Descargando $file..."
        (curl -fsSL "$RAW_BASE/$file" -o "$file" 2>/dev/null) &
        show_progress $!
        if [ $? -eq 0 ] && [ -f "$file" ]; then
            echo -e "\r✅ $file descargado correctamente"
            chmod +x "$file"
        else
            echo -e "\r❌ Error al descargar $file"
            return 1
        fi
    done
    
    return 0
}

# Hacer backup de configuraciones existentes
backup_existing() {
    if [ -f "/root/.bashrc" ] || [ -f "/root/.bash_profile" ]; then
        print_info "Haciendo backup de configuraciones existentes..."
        mkdir -p "$BACKUP_DIR"
        
        [ -f "/root/.bashrc" ] && cp "/root/.bashrc" "$BACKUP_DIR/bashrc.backup"
        [ -f "/root/.bash_profile" ] && cp "/root/.bash_profile" "$BACKUP_DIR/bash_profile.backup"
        [ -f "/root/.aws/config" ] && cp -r "/root/.aws" "$BACKUP_DIR/aws.backup" 2>/dev/null || true
        
        print_success "Backup creado en: $BACKUP_DIR"
    fi
}

# Configurar ejecución automática al iniciar sesión
configure_auto_start() {
    print_info "Configurando ejecución automática al iniciar sesión..."
    
    local bashrc_file="/root/.bashrc"
    local startup_line="[ -f '$INSTALL_DIR/aws-config-menu.sh' ] && '$INSTALL_DIR/aws-config-menu.sh'"
    
    # Verificar si ya existe la configuración
    if grep -q "aws-config-menu.sh" "$bashrc_file" 2>/dev/null; then
        print_warning "La configuración de auto-inicio ya existe"
        return 0
    fi
    
    # Añadir al final del .bashrc
    echo "" >> "$bashrc_file"
    echo "# Auto-start AWS CloudFront Manager" >> "$bashrc_file"
    echo "$startup_line" >> "$bashrc_file"
    
    print_success "Configuración de auto-inicio completada"
}

# Instalar dependencias
install_dependencies() {
    print_info "Instalando dependencias..."
    
    if [ -f "$INSTALL_DIR/dependencias-menu-aws.sh" ]; then
        cd "$INSTALL_DIR"
        ./dependencias-menu-aws.sh
    else
        print_error "No se encontró el script de dependencias"
        return 1
    fi
}

# Mostrar resumen de instalación
show_installation_summary() {
    print_header "🎉 INSTALACIÓN COMPLETADA"
    echo
    echo -e "${GREEN}✅ Qué se instaló:${NC}"
    echo "  • AWS CloudFront Manager en: $INSTALL_DIR"
    echo "  • Dependencias necesarias (AWS CLI, jq, bc)"
    echo "  • Configuración de auto-inicio en .bashrc"
    echo
    echo -e "${GREEN}🚀 Qué pasa ahora:${NC}"
    echo "  • Al iniciar sesión se ejecutará automáticamente aws-config-menu.sh"
    echo "  • Puedes ejecutar manualmente: $INSTALL_DIR/aws-config-menu.sh"
    echo
    echo -e "${YELLOW}📝 Próximos pasos:${NC}"
    echo "  1. Configurar tus credenciales AWS en el menú"
    echo "  2. Gestionar distribuciones CloudFront"
    echo "  3. Monitorear créditos y uso"
    echo
    echo -e "${BLUE}🔧 Comandos útiles:${NC}"
    echo "  • Ejecutar manualmente: $INSTALL_DIR/aws-config-menu.sh"
    echo "  • Ver logs: tail -f /tmp/aws-cloudfront/install.log"
    echo
}

# Función principal de instalación
main_installation() {
    print_header "🚀 INSTALADOR AUTOMÁTICO - AWS CLOUDFRONT MANAGER"
    echo
    
    check_root
    backup_existing
    create_install_dir
    
    if download_files; then
        configure_auto_start
        install_dependencies
        show_installation_summary
    else
        print_error "Error al descargar los archivos. Verifica la conexión o las URLs."
        exit 1
    fi
}

# Limpiar instalación (opcional)
cleanup_installation() {
    print_info "Limpiando instalación..."
    rm -rf "$INSTALL_DIR"
    # Remover línea de auto-start del .bashrc
    sed -i '/aws-config-menu.sh/d' /root/.bashrc 2>/dev/null || true
    print_success "Instalación limpiada correctamente"
}

# Menú principal
show_menu() {
    clear
    print_header "🔧 INSTALADOR - AWS CLOUDFRONT MANAGER"
    echo
    echo -e "${YELLOW}Este instalador automático hará:${NC}"
    echo "  1. 📥 Descargar los scripts desde GitHub"
    echo "  2. 🔧 Instalar todas las dependencias"
    echo "  3. ⚙️ Configurar ejecución automática al iniciar sesión"
    echo "  4. 🚀 Dejar todo listo para usar"
    echo
    echo -e "${RED}¿Continuar con la instalación automática?${NC}"
    echo "1. ✅ Sí, instalar todo automáticamente"
    echo "2. 🗑️ Limpiar instalación existente"
    echo "3. ❌ Cancelar"
    echo
    
    while true; do
        read -p "Selecciona una opción (1-3): " -r choice
        
        case $choice in
            1)
                echo
                print_warning "La instalación comenzará en 3 segundos..."
                sleep 3
                main_installation
                break
                ;;
            2)
                echo
                read -p "¿Estás seguro de limpiar la instalación? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    cleanup_installation
                else
                    print_info "Operación cancelada"
                fi
                break
                ;;
            3)
                print_info "Instalación cancelada"
                exit 0
                ;;
            *)
                print_error "Opción no válida. Selecciona 1, 2 o 3."
                ;;
        esac
    done
}

# Manejar Ctrl+C
trap 'echo -e "\n${YELLOW}Instalación interrumpida por el usuario${NC}"; exit 1' INT
