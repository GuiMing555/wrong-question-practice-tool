using System.Windows;
using MedicalQuestionPractice.Windows.Services;
using MedicalQuestionPractice.Windows.ViewModels;

namespace MedicalQuestionPractice.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        try
        {
            var service = new QuestionBankService();
            var viewModel = new MainViewModel(service);
            var window = new MainWindow { DataContext = viewModel };
            MainWindow = window;
            window.Show();
            _ = viewModel.InitializeAsync();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                $"无法打开本地题库。\n\n{exception.Message}",
                "错题刷题工具",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
