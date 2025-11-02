#!/bin/bash

# Script de instalación de dependencias para AWS CloudFront Manager
# Ubicación: /root/aws-cloudfront-manager/dependencias-menu-aws.sh

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

# Verificar si el sistema es Ubuntu/Debian
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            print_error "Este script solo es compatible con Ubuntu/Debian"
            exit 1
        fi
    else
        print_error "No se pudo detectar el sistema operativo"
        exit 1
    fi
}

# Actualizar sistema completo
update_system() {
    print_header "🔄 ACTUALIZANDO SISTEMA COMPLETO"
    echo
    
    print_info "Actualizando lista de paquetes (apt update)..."
    (apt-get update > /dev/null 2>&1) &
    show_progress $!
    echo -e "\r✅ Lista de paquetes actualizada"
    
    print_info "Actualizando paquetes (apt upgrade)..."
    (DEBIAN_FRONTEND=noninteractive apt-get upgrade -y > /dev/null 2>&1) &
    show_progress $!
    echo -e "\r✅ Sistema actualizado"
    
    print_info "Limpiando paquetes innecesarios..."
    (apt-get autoremove -y > /dev/null 2>&1) &
    show_progress $!
    echo -e "\r✅ Sistema limpiado"
    
    print_success "✅ Sistema completamente actualizado"
    echo
}

# Verificar dependencias existentes
check_existing_dependencies() {
    local missing=()
    
    print_info "Verificando dependencias existentes..."
    
    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        missing+=("awscli")
    else
        local aws_version
        aws_version=$(aws --version 2>&1 | head -n1)
        print_success "✓ AWS CLI ya está instalado: $aws_version"
    fi
    
    # Verificar jq
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    else
        print_success "✓ jq ya está instalado: $(jq --version)"
    fi
    
    # Verificar bc
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    else
        print_success "✓ bc ya está instalado: $(bc --version | head -n1)"
    fi
    
    # Verificar curl (necesario para AWS CLI)
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    else
        print_success "✓ curl ya está instalado"
    fi
    
    # Verificar unzip (necesario para AWS CLI)
    if ! command -v unzip &> /dev/null; then
        missing+=("unzip")
    else
        print_success "✓ unzip ya está instalado"
    fi
    
    echo "${missing[@]}"
}

# Instalar AWS CLI v2 (método oficial)
install_aws_cli_v2() {
    print_info "Instalando AWS CLI v2 (método oficial)..."
    
    # Crear directorio temporal
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Descargar el instalador oficial de AWS CLI v2
    (curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" > /dev/null 2>&1) &
    show_progress $!
    echo -e "\r✅ AWS CLI v2 descargado"
    
    # Descomprimir
    (unzip -q awscliv2.zip > /dev/null 2>&1) &
    show_progress $!
    echo -e "\r✅ AWS CLI v2 descomprimido"
    
    # Instalar
    (./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update > /dev/null 2>&1) &
    show_progress $!
    echo -e "\r✅ AWS CLI v2 instalado"
    
    # Limpiar archivos temporales
    cd /
    rm -rf "$temp_dir"
    
    # Verificar instalación
    if command -v aws &> /dev/null; then
        local aws_version
        aws_version=$(aws --version 2>&1)
        print_success "✓ AWS CLI instalado correctamente: $aws_version"
        return 0
    else
        print_error "❌ AWS CLI no se pudo instalar correctamente"
        return 1
    fi
}

# Instalar dependencias del sistema
install_system_dependencies() {
    local packages=("curl" "unzip" "jq" "bc")
    local package_names=("curl" "unzip" "jq" "bc")
    
    for i in "${!packages[@]}"; do
        print_info "Instalando ${package_names[$i]}..."
        (apt-get install -y "${packages[$i]}" > /dev/null 2>&1) &
        show_progress $!
        echo -e "\r✅ ${package_names[$i]} instalado correctamente"
    done
}

# Instalar todas las dependencias
install_all_dependencies() {
    print_header "🚀 INSTALANDO TODAS LAS DEPENDENCIAS"
    echo
    
    # Primero actualizar el sistema completo
    update_system
    
    # Instalar dependencias del sistema
    install_system_dependencies
    
    # Instalar AWS CLI v2
    if ! install_aws_cli_v2; then
        print_error "Falló la instalación de AWS CLI v2, intentando método alternativo..."
        
        # Método alternativo: instalar desde repositorio
        print_info "Intentando instalación desde repositorio..."
        (apt-get install -y awscli > /dev/null 2>&1) &
        show_progress $!
        
        if command -v aws &> /dev/null; then
            print_success "✓ AWS CLI instalado desde repositorio"
        else
            print_error "❌ No se pudo instalar AWS CLI con ningún método"
            return 1
        fi
    fi
    
    # Verificación final
    print_info "Verificando instalaciones..."
    local all_installed=true
    
    if ! command -v aws &> /dev/null; then
        print_error "❌ AWS CLI no se instaló correctamente"
        all_installed=false
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "❌ jq no se instaló correctamente"
        all_installed=false
    fi
    
    if ! command -v bc &> /dev/null; then
        print_error "❌ bc no se instaló correctamente"
        all_installed=false
    fi
    
    if [ "$all_installed" = true ]; then
        print_success "🎉 ¡Todas las dependencias se instalaron correctamente!"
        echo
        echo -e "${GREEN}Herramientas instaladas:${NC}"
        echo "  • $(aws --version 2>&1)"
        echo "  • jq $(jq --version)"
        echo "  • bc $(bc --version | head -n1)"
        return 0
    else
        print_error "Algunas dependencias no se instalaron correctamente"
        return 1
    fi
}

# Menú principal
show_menu() {
    clear
    print_header "🔧 INSTALADOR DE DEPENDENCIAS - AWS CLOUDFRONT MANAGER"
    echo
    echo -e "${YELLOW}Este script instalará y actualizará:${NC}"
    echo "  • ✅ Sistema completo (apt update && apt upgrade)"
    echo "  • ✅ AWS CLI v2 - Interfaz oficial de AWS"
    echo "  • ✅ jq - Procesador de JSON"
    echo "  • ✅ bc - Calculadora matemática"
    echo "  • ✅ curl & unzip - Herramientas necesarias"
    echo
    echo -e "${YELLOW}⚠️  Requiere conexión a Internet y privilegios de root${NC}"
    echo
    
    # Verificar dependencias existentes primero
    local missing_deps
    missing_deps=$(check_existing_dependencies)
    
    if [ -z "$missing_deps" ]; then
        print_success "✅ Todas las dependencias ya están instaladas"
        echo
        read -p "¿Deseas actualizar el sistema y reinstalar dependencias? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Saliendo sin realizar cambios"
            exit 0
        fi
    else
        echo -e "${YELLOW}Dependencias faltantes detectadas:${NC}"
        for dep in $missing_deps; do
            case $dep in
                "awscli") echo "  • AWS CLI" ;;
                "jq") echo "  • jq" ;;
                "bc") echo "  • bc" ;;
                "curl") echo "  • curl" ;;
                "unzip") echo "  • unzip" ;;
            esac
        done
        echo
    fi
    
    echo -e "${RED}¿Continuar con la instalación COMPLETA del sistema?${NC}"
    echo "1. ✅ Sí, instalar y actualizar TODO"
    echo "2. ❌ No, cancelar la instalación"
    echo
    
    while true; do
        read -p "Selecciona una opción (1-2): " -r choice
        
        case $choice in
            1)
                echo
                print_warning "La instalación COMPLETA comenzará en 5 segundos..."
                print_warning "Esto incluye apt update && apt upgrade"
                sleep 5
                if install_all_dependencies; then
                    echo
                    print_success "¡Instalación completada exitosamente!"
                    echo
                    echo -e "${GREEN}Ahora puedes ejecutar:${NC}"
                    echo -e "${BLUE}/root/aws-cloudfront-manager/aws-config-menu.sh${NC}"
                    echo
                else
                    echo
                    print_error "La instalación falló. Por favor, revisa los mensajes de error."
                    echo
                    echo -e "${YELLOW}Posibles soluciones:${NC}"
                    echo "1. Verifica tu conexión a Internet"
                    echo "2. Ejecuta manualmente: apt-get update && apt-get upgrade"
                    echo "3. Intenta instalar AWS CLI manualmente:"
                    echo "   - curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip"
                    echo "   - unzip awscliv2.zip"
                    echo "   - sudo ./aws/install"
                    exit 1
                fi
                break
                ;;
            2)
                print_info "Instalación cancelada por el usuario"
                exit 0
                ;;
            *)
                print_error "Opción no válida. Selecciona 1 o 2."
                ;;
        esac
    done
}

# Función principal
main() {
    # Verificar si es root
    if [ "$EUID" -ne 0 ]; then
        print_error "Este script debe ejecutarse como root"
        echo "Usa: sudo ./dependencias-menu-aws.sh"
        exit 1
    fi
    
    # Verificar sistema operativo
    check_os
    
    # Mostrar menú
    show_menu
}

# Manejar Ctrl+C
trap 'echo -e "\n${YELLOW}Instalación interrumpida por el usuario${NC}"; exit 1' INT

# Ejecutar función principal