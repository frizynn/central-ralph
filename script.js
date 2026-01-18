/**
 * Personal Landing Page - Main JavaScript
 * Handles form validation, navigation, and interactive elements
 */

(function() {
    'use strict';

    /**
     * Initialize the application
     */
    function init() {
        initContactForm();
        initNavigation();
    }

    /**
     * Initialize contact form with validation and submission handling
     */
    function initContactForm() {
        const form = document.getElementById('contactForm');
        if (!form) return;

        const confirmation = document.getElementById('formConfirmation');

        form.addEventListener('submit', function(e) {
            e.preventDefault();

            // Clear previous states
            confirmation.className = 'form-confirmation';
            confirmation.textContent = '';

            // Validate form
            const isValid = validateForm(form);
            if (!isValid) {
                showConfirmation(confirmation, 'Please fill in all required fields correctly.', 'error');
                return;
            }

            // Simulate form submission
            const formData = new FormData(form);
            const data = Object.fromEntries(formData.entries());

            // Log form data (in production, this would be sent to a server)
            console.log('Form submitted:', data);

            // Show success message
            showConfirmation(confirmation, 'Thank you for your message! I will get back to you soon.', 'success');

            // Reset form
            form.reset();
        });
    }

    /**
     * Validate form fields
     * @param {HTMLFormElement} form - The form to validate
     * @returns {boolean} - Whether the form is valid
     */
    function validateForm(form) {
        const name = form.querySelector('#name');
        const email = form.querySelector('#email');
        const projectSummary = form.querySelector('#projectSummary');

        let isValid = true;

        // Validate name
        if (!name.value.trim()) {
            markFieldAsError(name);
            isValid = false;
        } else {
            clearFieldError(name);
        }

        // Validate email
        if (!isValidEmail(email.value)) {
            markFieldAsError(email);
            isValid = false;
        } else {
            clearFieldError(email);
        }

        // Validate project summary
        if (!projectSummary.value.trim()) {
            markFieldAsError(projectSummary);
            isValid = false;
        } else {
            clearFieldError(projectSummary);
        }

        return isValid;
    }

    /**
     * Validate email format
     * @param {string} email - Email to validate
     * @returns {boolean} - Whether the email is valid
     */
    function isValidEmail(email) {
        const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        return emailRegex.test(email.trim());
    }

    /**
     * Mark a form field as having an error
     * @param {HTMLElement} field - The field to mark
     */
    function markFieldAsError(field) {
        field.style.borderColor = '#e94560';
        field.setAttribute('aria-invalid', 'true');
    }

    /**
     * Clear error state from a form field
     * @param {HTMLElement} field - The field to clear
     */
    function clearFieldError(field) {
        field.style.borderColor = '';
        field.removeAttribute('aria-invalid');
    }

    /**
     * Show confirmation message
     * @param {HTMLElement} element - The confirmation element
     * @param {string} message - Message to display
     * @param {string} type - Message type ('success' or 'error')
     */
    function showConfirmation(element, message, type) {
        element.textContent = message;
        element.classList.add(type);
    }

    /**
     * Initialize smooth scrolling navigation
     */
    function initNavigation() {
        const navLinks = document.querySelectorAll('.nav-links a');

        navLinks.forEach(function(link) {
            link.addEventListener('click', function(e) {
                const href = this.getAttribute('href');
                if (href.startsWith('#')) {
                    e.preventDefault();
                    const targetId = href.substring(1);
                    const targetElement = document.getElementById(targetId);

                    if (targetElement) {
                        const navHeight = document.querySelector('.navigation').offsetHeight;
                        const targetPosition = targetElement.offsetTop - navHeight;

                        window.scrollTo({
                            top: targetPosition,
                            behavior: 'smooth'
                        });
                    }
                }
            });
        });
    }

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
